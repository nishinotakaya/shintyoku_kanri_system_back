require "net/http"
require "json"
require "uri"

# freee 会計に登録済みの経費(deal=取引)を取得し、business_expenses に保存する。
# freee 内部 Web API を利用（公式 OAuth ではない。SessionLogin と同じ仕組み）。
#
#   GET /api/p/deals?deal_type=expense&start_issue_date&end_issue_date  経費一覧(勘定科目付き)
#   GET /api/p/receipts/{id}                                           レシート画像メタ
#   PUT /api/p/v2/walletables/bank_account/{id}/sync                   銀行明細を最新化
#
# freee が details[].account_item_name に勘定科目を割り当て済みなので、
# それをアプリの BusinessExpense::ACCOUNT_CATEGORIES へ名寄せして取り込む(AI推論不要)。
module Freee
  class ExpenseImporter
    DEALS_URL       = "https://secure.freee.co.jp/api/p/deals".freeze
    WALLETABLES_URL = "https://secure.freee.co.jp/api/p/walletables".freeze
    RECEIPT_URL     = "https://secure.freee.co.jp/api/p/receipts".freeze
    SYNC_URL_TMPL   = "https://secure.freee.co.jp/api/p/v2/walletables/bank_account/%<id>d/sync".freeze
    USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze
    PAGE = 100

    # freee 標準科目名 → アプリ ACCOUNT_CATEGORIES の別名変換(一致するものは変換不要)。
    ACCOUNT_ALIASES = {
      "交際費" => "接待交際費", "外注費" => "外注工賃", "支払利息" => "利子割引料",
      "事務用品費" => "消耗品費", "図書研修費" => "新聞図書費", "研修費" => "新聞図書費",
      "諸会費" => "雑費", "ソフトウェア" => "消耗品費" # SaaS/ソフト購入。資産計上したい場合は要確認
    }.freeze

    # 経費(P&L)ではない勘定科目 → 取込しない(事業主貸/資産/負債/売上原価など)。
    # tax_summary の経費合計を汚さないため。
    # 外注費/外注工賃は TaxSummaryBuilder の subcontract ロジック(川村分の承認済請求を合算)で
    # 別途計上するため、ここで取り込むと二重計上になる → 除外する。
    NON_EXPENSE = %w[
      外注費 外注工賃
      事業主貸 事業主借 現金 普通預金 当座預金 売掛金 買掛金 未払金 未収入金 前払金 前受金
      預り金 仮払金 仮受金 元入金 貸付金 借入金 短期借入金 長期借入金 役員借入金
      売上高 仕入高 期首商品棚卸高 期末商品棚卸高
    ].freeze

    def initialize(connection:, company_id: nil, user: nil)
      @conn = connection
      @user = user || connection.user
      @company_id = (company_id || connection.company_id || ENV["FREEE_COMPANY_ID"]).to_s
    end

    # 保存済み cookie は失効しがちなので、実行前に再ログインして session_cookie/csrf を更新する。
    def refresh_session!
      result = Freee::SessionLogin.new(identity: @conn.identity, password: @conn.password_encrypted).call
      return false unless result.ok?
      @conn.update!(
        session_cookie: result.session_cookie,
        csrf_token: result.csrf_token,
        company_id: result.company_id.presence || @conn.company_id,
        last_connected_at: Time.current, status: "connected", last_status_code: 200
      )
      @company_id = @conn.company_id.to_s
      true
    end

    # 経費 deal を明細行に展開して business_expenses に保存する。
    # 戻り値: { imported:, skipped_duplicate:, skipped_non_expense:, unmapped: {科目=>件数},
    #          receipts_saved:, by_month: {"2025-01"=>{count:,amount:}}, total_deals: }
    def import!(start_date:, end_date:, download_receipts: false)
      ctx!
      rows = fetch_expense_rows(start_date, end_date)
      existing = @user.business_expenses.where(import_hash: rows.map { |r| r[:import_hash] }).pluck(:import_hash).to_set

      imported = 0
      dup = 0
      receipts_saved = 0
      by_month = Hash.new { |h, k| h[k] = { count: 0, amount: 0 } }

      rows.each do |row|
        if existing.include?(row[:import_hash])
          dup += 1
          next
        end
        attrs = {
          expense_date: (Date.iso8601(row[:date]) rescue Date.current),
          store_name: row[:description].presence,
          amount: row[:amount],
          tax_rate: row[:tax_rate],
          account_category: row[:account_category],
          memo: row[:memo].presence,
          business_ratio: 100,
          status: row[:account_category] ? "confirmed" : "needs_review",
          source: "freee",
          import_hash: row[:import_hash]
        }
        if download_receipts && row[:receipt_id]
          image = fetch_receipt_image(row[:receipt_id])
          if image
            attrs[:receipt_data] = image[:bytes]
            attrs[:content_type] = image[:content_type]
            receipts_saved += 1
          end
        end
        @user.business_expenses.create!(attrs)
        imported += 1
        month = row[:date].to_s[0, 7]
        by_month[month][:count] += 1
        by_month[month][:amount] += row[:amount]
      end

      {
        total_deals: @last_total,
        imported: imported,
        skipped_duplicate: dup,
        skipped_non_expense: @skipped_non_expense,
        unmapped: @unmapped,
        receipts_saved: receipts_saved,
        by_month: by_month.sort.to_h
      }
    end

    # 連携済みの全口座(銀行 + クレカ)を freee 経由で同期(最新明細を取り込む)。
    # sync パスは type の snake_case (bank_account / credit_card)。現金(Wallet)は同期不可。
    # 戻り値: [{ id:, name:, type:, ok:, status:, message: }]
    def sync_banks!
      ctx!
      syncable_accounts.map do |account|
        path_type = account[:type] == "CreditCard" ? "credit_card" : "bank_account"
        uri = URI("https://secure.freee.co.jp/api/p/v2/walletables/#{path_type}/#{account[:id]}/sync?company_id=#{@company_id}")
        res = put(uri)
        ok = res.code.start_with?("2")
        msg = ok ? nil : (parse_message(res.body) || "同期開始できませんでした")
        { id: account[:id], name: account[:name], type: account[:type], ok: ok, status: res.code.to_i, message: msg }
      end
    end
    alias sync_accounts! sync_banks!

    # 未処理(未登録)の入出金明細を import_commit 行フォーマットで返す。
    # freee の「自動で経理」相当: 銀行/カードの明細に freee 推奨科目を割り当てて提示する。
    def unreconciled_txns(start_date:, end_date:, side: "expense")
      ctx!
      rows = syncable_accounts.flat_map do |account|
        path_type = account[:type] == "CreditCard" ? "credit_card" : "bank_account"
        fetch_wallet_txns(account, path_type, start_date, end_date, side)
      end
      existing = @user.business_expenses.where(import_hash: rows.map { |r| r[:import_hash] }).pluck(:import_hash).to_set
      rows.map { |r| r.merge(duplicate: existing.include?(r[:import_hash])) }
          .reject { |r| r[:reconciled] } # 既に取引登録済みの明細は除外
          .sort_by { |r| r[:date].to_s }
    end

    private

    def syncable_accounts
      list = json(get(URI("https://secure.freee.co.jp/api/p/v2/walletables?company_id=#{@company_id}")))&.dig("walletables") || []
      list.select { |w| %w[BankAccount CreditCard].include?(w["type"]) }
          .map { |w| { id: w["id"], name: w["name"], type: w["type"] } }
    end

    # 1口座の wallet_txns を import_commit 行に変換。
    def fetch_wallet_txns(account, walletable_type, start_date, end_date, side)
      rows = []
      offset = 0
      loop do
        uri = URI("https://secure.freee.co.jp/api/p/wallet_txns?" + URI.encode_www_form(
          company_id: @company_id, walletable_type: walletable_type, walletable_id: account[:id],
          start_date: start_date.to_s, end_date: end_date.to_s, limit: PAGE, offset: offset
        ))
        body = json(get(uri))
        models = body&.dig("models") || []
        models.each do |txn|
          next unless txn["entry_side_str"] == side
          amount = txn["get_spent_amount"].to_i
          next if amount.zero?
          rows << {
            date: txn["txn_date"],
            description: txn["description"].to_s,
            amount: amount,
            account_category: map_account(txn["suggested_account_item"]),
            tax_rate: tax_rate_from(txn["suggested_tax"]),
            memo: [ account[:name], "freee明細" ].compact.join(" / "),
            import_hash: "freee_wtxn:#{txn['id']}",
            freee_suggested: txn["suggested_account_item"],
            reconciled: txn["status_str"] != "unreconciled"
          }
        end
        total = body&.dig("info", "total").to_i
        offset += PAGE
        break if offset >= total || models.empty?
      end
      rows
    end

    def parse_message(body)
      JSON.parse(body.to_s.force_encoding("UTF-8").scrub)["message"]
    rescue StandardError
      nil
    end

    def ctx!
      @ctx ||= Freee::AccountingContext.new(connection: @conn, company_id: @company_id).refresh!(path: "/deals/standards")
      @unmapped ||= Hash.new(0)
      @skipped_non_expense ||= 0
    end

    def bank_accounts
      list = json(get(URI("#{WALLETABLES_URL}?company_id=#{@company_id}")))&.dig("walletables") || []
      list.select { |w| w["type"] == "bank_account" }.map { |w| { id: w["id"], name: w["name"] } }
    end

    # 経費 deal を「明細(debit=費用側)1行 = business_expense 1件」に展開する。
    def fetch_expense_rows(start_date, end_date)
      rows = []
      offset = 0
      @last_total = 0
      loop do
        uri = URI("#{DEALS_URL}?" + URI.encode_www_form(
          company_id: @company_id, deal_type: "expense",
          start_issue_date: start_date.to_s, end_issue_date: end_date.to_s,
          limit: PAGE, offset: offset
        ))
        body = json(get(uri))
        models = body&.dig("models") || []
        @last_total = body&.dig("info", "total").to_i
        models.each { |deal| rows.concat(rows_from_deal(deal)) }
        offset += PAGE
        break if offset >= @last_total || models.empty?
      end
      rows
    end

    def rows_from_deal(deal)
      receipt_id = (deal["receipts"] || []).first&.dig("id")
      details = deal["details"] || []
      # 費用側(借方)の明細のみ。account_item が P&L 経費でないものは除外。
      details.select { |d| d["entry_side"] == "debit" }.filter_map do |detail|
        raw_name = detail.dig("account_item", "name") || detail["account_item_name"]
        if NON_EXPENSE.include?(raw_name.to_s)
          @skipped_non_expense += 1
          next
        end
        category = map_account(raw_name)
        @unmapped[raw_name.to_s] += 1 if category.nil? && raw_name.present?
        {
          date: detail["txn_date"] || deal["issue_date"],
          description: (deal["partner_name"] || detail["description"] || raw_name).to_s,
          amount: detail["amount"].to_i.abs,
          account_category: category,
          tax_rate: tax_rate_from(detail["tax_name"]),
          memo: [ "freee", raw_name, deal["partner_name"] ].compact.reject(&:blank?).uniq.join(" / "),
          import_hash: "freee_deal:#{deal['id']}:#{detail['id']}",
          receipt_id: receipt_id
        }
      end
    end

    def map_account(freee_name)
      name = freee_name.to_s
      mapped = ACCOUNT_ALIASES[name] || name
      BusinessExpense::ACCOUNT_CATEGORIES.include?(mapped) ? mapped : nil
    end

    def tax_rate_from(tax_name)
      s = tax_name.to_s
      return 8 if s.include?("8")
      return 0 if s.include?("対象外") || s.include?("非課") || s.include?("不課")
      10
    end

    # レシート画像の実バイトを取得。
    # freee は画像を filebox サブドメインの file_revisions/{revision}/image で配信する
    # (SPA が blob 化して表示。secure.freee.co.jp 側の /receipts/{id}/download は HTML ビューア)。
    # 注意: 原本は数MB。本番にリサイズ用バイナリ(vips/convert)が無いため、
    #       過去分の一括取込はローカルで縮小して投入済み。ここは増分用(原寸保存)。
    def fetch_receipt_image(receipt_id)
      meta = json(get(URI("#{RECEIPT_URL}/#{receipt_id}?company_id=#{@company_id}")))&.dig("receipt")
      revision = meta&.dig("current_revision_id")
      return nil unless revision
      res = get(URI("https://filebox.secure.freee.co.jp/api/p/file_revisions/#{revision}/image"))
      return nil unless res.code == "200" && res["content-type"].to_s.start_with?(%r{image|application/pdf})
      { bytes: res.body, content_type: res["content-type"].split(";").first }
    rescue StandardError => e
      Rails.logger.warn("[Freee::ExpenseImporter#fetch_receipt_image] #{receipt_id}: #{e.class} #{e.message}")
      nil
    end

    # === HTTP ===
    def get(uri)
      http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 40 }
      req = Net::HTTP::Get.new(uri.request_uri)
      common(req)
      http.request(req)
    end

    def put(uri)
      http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 40 }
      req = Net::HTTP::Put.new(uri.request_uri)
      common(req)
      req["content-length"] = "0"
      req["origin"] = "https://secure.freee.co.jp"
      http.request(req)
    end

    def common(req)
      req["accept"] = "application/json, */*"
      req["accept-language"] = "ja,en-US;q=0.9,en;q=0.8"
      req["user-agent"] = USER_AGENT
      req["x-requested-with"] = "XMLHttpRequest"
      req["x-company-id"] = @company_id
      req["x-csrf-token"] = (@ctx&.csrf || @conn.csrf_token).to_s
      req["x-xhr-from"] = "api-clients"
      req["cookie"] = (@ctx&.cookie || @conn.session_cookie).to_s
    end

    def json(res)
      return nil unless res.code == "200"
      JSON.parse(res.body)
    rescue JSON::ParserError
      nil
    end
  end
end
