require "net/http"
require "json"
require "uri"

# freee 会計に売上計上の取引（deal）を登録する。
# - 取引先: 株式会社ラボップ (partner_id=117037205) 固定
# - 勘定科目: 売上高 (account_item_id=529051105)
# - 税区分: 課税売上 10% (tax_code=129, 内税 tax_entry_method=1)
# - 口座: 現金 wallet (from_walletable_id=3746169)
#
# 提供された curl をそのまま再現:
#   1) /api/p/deals/previews/standard  (preview)
#   2) /api/p/deals/standard           (本登録)
module Freee
  class ReportSale
    PREVIEW_URL = "https://secure.freee.co.jp/api/p/deals/previews/standard"
    DEAL_URL    = "https://secure.freee.co.jp/api/p/deals/standard"

    # 取引先固定マッピング（提供された curl + env から）
    # テックリーダーズの partner_id は freee 取引先一覧 API で取得する必要があるため env で設定可能に。
    PARTNER_ID_LABOP = 117037205
    PARTNERS_BY_CATEGORY = {
      "wings"        => { id: PARTNER_ID_LABOP, name: "株式会社ラボップ" },
      "living"       => { id: PARTNER_ID_LABOP, name: "株式会社ラボップ" },
      "techleaders"  => { id: nil, name: "株式会社テックリーダーズ" }, # env FREEE_PARTNER_TECHLEADERS
      "resystems"    => { id: nil, name: "株式会社REシステムズ" }
    }.freeze

    ACCOUNT_ITEM_SALES = 529051105  # 売上高
    TAX_CODE_INCOME_10 = 129          # 課税売上 10%
    TAX_ENTRY_METHOD_INCLUDED = 1     # 内税
    WALLET_CASH = 3746169             # 現金 wallet

    # 経費用 (env で上書き可能)
    DEFAULT_ACCOUNT_ITEM_OUTSOURCING = (ENV["FREEE_ACCOUNT_ITEM_OUTSOURCING"] || 0).to_i  # 外注費
    # tax_code は 2026-07-11 に freee preview API へ実コードを投げて tax_name を読み取り実測確定した値。
    #   136=課対仕入10% / 163=課対仕入8%（軽） / 2=対象外
    TAX_CODE_EXPENSE_10 = (ENV["FREEE_TAX_CODE_EXPENSE_10"] || 136).to_i # 課対仕入 10%
    TAX_CODE_EXPENSE_8  = (ENV["FREEE_TAX_CODE_EXPENSE_8"] || 163).to_i  # 課対仕入 8%（軽減税率）
    TAX_CODE_EXPENSE_0  = (ENV["FREEE_TAX_CODE_EXPENSE_0"] || 2).to_i    # 対象外

    # category から partner_id を解決する。
    # 1) ENV FREEE_PARTNER_<UPCASE_CATEGORY> > 2) PARTNERS_BY_CATEGORY > 3) 既定でラボップ
    def self.resolve_partner_id(category)
      env_key = "FREEE_PARTNER_#{category.to_s.upcase}"
      env_id = ENV[env_key]
      return env_id.to_i if env_id.present?
      PARTNERS_BY_CATEGORY.dig(category.to_s, :id) || PARTNER_ID_LABOP
    end

    Result = Struct.new(:ok?, :status, :body, :deal_id, :error, keyword_init: true)

    # invoice: { total_amount:, due_date:, subject:(optional), category:(optional), partner_id:(optional) }
    # conn: FreeeConnection (session_cookie + csrf_token + company_id)
    # company_id_override: env で渡される company_id を優先
    # transaction_type: 'income' (売上) | 'expense' (経費)
    # account_item_id: 経費の場合は外注費等の科目 id (env or 引数)
    # tax_rate: 経費の税率 (10/8/0)。income は既存通り常に 10% 固定で挙動を変えない。
    def initialize(invoice:, connection:, company_id: nil, preview_only: false, transaction_type: "income", account_item_id: nil, tax_rate: nil)
      @invoice = invoice
      @conn = connection
      @company_id = (company_id || @conn.company_id || ENV["FREEE_COMPANY_ID"]).to_s
      @preview_only = preview_only
      @transaction_type = transaction_type.to_s
      @tax_rate = tax_rate&.to_i
      # 経費(expense)は freee 上でも取引先なしで登録できるため、partner_id は任意(nil可)。
      # 売上(income)は従来どおりカテゴリ既定値へフォールバックし、未解決なら例外。
      @partner_id =
        if @transaction_type == "expense"
          value = @invoice[:partner_id].to_i
          value.zero? ? nil : value
        else
          (@invoice[:partner_id] || self.class.resolve_partner_id(@invoice[:category] || "wings")).to_i
        end
      @account_item_id = (account_item_id ||
                          (@transaction_type == "expense" ? DEFAULT_ACCOUNT_ITEM_OUTSOURCING : ACCOUNT_ITEM_SALES)).to_i
      raise "company_id 未設定。FREEE_COMPANY_ID を設定してください。" if @company_id.blank?
      if @transaction_type != "expense" && @partner_id.to_i.zero?
        raise "partner_id 未設定 (category=#{@invoice[:category]})。FREEE_PARTNER_<CATEGORY> を設定してください。"
      end
      if @transaction_type == "expense" && @account_item_id.zero?
        raise "account_item_id 未設定 (経費連携)。FREEE_ACCOUNT_ITEM_OUTSOURCING を設定してください。"
      end
    end

    def call
      total = @invoice[:total_amount].to_i
      vat = compute_vat(total)
      due = @invoice[:due_date].to_s

      # 0) accounting アプリの context を取得（cu_cid cookie + 最新 CSRF）
      # /deals/standards?company_id=XXX を開くと cu_cid cookie が set されて
      # HTML の meta タグから新しい CSRF token が取れる。
      refresh_accounting_context!

      # 1) preview
      pv_res = post(PREVIEW_URL, preview_payload(total, vat, due))
      return Result.new(ok?: false, status: pv_res.code.to_i, body: pv_res.body, error: "preview 失敗") unless pv_res.code.start_with?("2")

      if @preview_only
        return Result.new(ok?: true, status: pv_res.code.to_i, body: pv_res.body)
      end

      # 2) deal 本登録
      res = post(DEAL_URL, deal_payload(total, vat, due))
      json = (JSON.parse(res.body) rescue {})
      Result.new(
        ok?: res.code.start_with?("2"),
        status: res.code.to_i,
        body: res.body,
        deal_id: json.dig("deal", "id"),
        error: res.code.start_with?("2") ? nil : "deal 登録失敗 (status=#{res.code})"
      )
    rescue StandardError => e
      Result.new(ok?: false, status: 0, error: "#{e.class}: #{e.message}")
    end

    private

    # accounting アプリの GET /deals/standards を一度叩いて、cu_cid cookie + 最新 CSRF を取得する。
    # 共通実装は Freee::AccountingContext に切り出し済。
    def refresh_accounting_context!
      ctx = Freee::AccountingContext.new(connection: @conn, company_id: @company_id).refresh!
      @effective_cookie = ctx.cookie
      @effective_csrf = ctx.csrf
    end

    # 消費税額。income は既存通り 10%内税で固定。expense は tax_rate (8/0/それ以外=10) で算出する。
    def compute_vat(total)
      return (total * 10.0 / 110.0).round unless @transaction_type == "expense"
      case @tax_rate
      when 8 then (total * 8.0 / 108.0).round
      when 0 then 0
      else (total * 10.0 / 110.0).round
      end
    end

    # freee 内部 API の tax_code。income は既存通り TAX_CODE_INCOME_10 固定。
    def tax_code
      return TAX_CODE_INCOME_10 unless @transaction_type == "expense"
      case @tax_rate
      when 8 then TAX_CODE_EXPENSE_8
      when 0 then TAX_CODE_EXPENSE_0
      else TAX_CODE_EXPENSE_10
      end
    end

    def preview_payload(total, vat, due)
      {
        deal: {
          issue_date: due,
          transactions_attributes: {
            "0" => {
              line_items_attributes: [ {
                default_tags_id: [],
                default_tags_name: "",
                description: @invoice[:subject].to_s,
                qty: 1,
                tax_code: tax_code,
                tax_entry_method: TAX_ENTRY_METHOD_INCLUDED,
                type: "positive",
                unit_price: total,
                vat: vat,
                vat_system_calc: 0,
                partner_id: @partner_id
              } ]
            }
          }
        },
        deal_code: @transaction_type,
        is_skip_update_deal: true,
        payment_walletable: "現金"
      }
    end

    def deal_payload(total, vat, due)
      {
        details: [ {
          account_item_id: @account_item_id,
          amount: total,
          default_tag_ids: [],
          description: @invoice[:subject].to_s,
          partner_id: @partner_id,
          tax_code: tax_code,
          tax_entry_method: TAX_ENTRY_METHOD_INCLUDED,
          vat: vat
        } ],
        issue_date: due,
        partner_id: @partner_id,
        payments: [ {
          amount: total,
          date: due,
          from_walletable_id: WALLET_CASH,
          from_walletable_type: "wallet"
        } ],
        receipts: [],
        ref: "",
        type: @transaction_type,
        from_nde: true
      }
    end

    def post(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri.path)
      req["accept"] = "application/json"
      req["content-type"] = "application/json; charset=UTF-8"
      req["origin"] = "https://secure.freee.co.jp"
      req["referer"] = "https://secure.freee.co.jp/deals/standards"
      req["user-agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/148.0.0.0 Safari/537.36"
      req["x-company-id"] = @company_id
      req["x-csrf-token"] = (@effective_csrf || @conn.csrf_token).to_s
      req["x-xhr-from"] = "request-ts"
      req["cookie"] = (@effective_cookie || @conn.session_cookie).to_s
      req.body = payload.to_json

      http.request(req)
    end
  end
end
