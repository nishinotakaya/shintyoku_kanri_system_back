require "open3"
require "fileutils"
require "erb"

# 月次の業務報告から請求金額を計算し、HTML を生成して
# Playwright Chromium で PDF に変換する。
class InvoicePdfRenderer
  TEMPLATE = Rails.root.join("app/views/invoices/invoice.html.erb")
  SCRIPT   = Rails.root.join("lib/exporters/html_to_pdf.mjs")

  def initialize(user, year:, month:, category: nil, application_date: nil,
                 client_name_override: nil, issuer_user_override: nil,
                 total_override: nil, item_label_override: nil, subject_override: nil,
                 items_override: nil, note: nil, merged_users: nil, title_override: nil,
                 due_date_override: nil, registration_no_override: nil, bank_info_override: nil)
    @user = user
    @year = year
    @month = month
    @category = category
    @application_date = application_date
    @due_date_override = due_date_override # 請求書ごとの支払期限上書き（nil なら設定から計算）
    @registration_no_override = registration_no_override.to_s.presence # インボイス番号の請求書単体上書き
    @bank_info_override = bank_info_override.to_s.presence # 振込先の請求書単体上書き（nil なら設定の bank_info）
    @client_name_override = client_name_override.presence
    @issuer_user = issuer_user_override || user
    @total_override = total_override.to_i if total_override.present?
    @item_label_override = item_label_override.to_s.presence
    @subject_override = subject_override.to_s.presence
    @items_override = items_override if items_override.is_a?(Array) && items_override.any?
    @note = note.to_s.presence # 備考欄に出すテキスト（発注番号など）
    @title_override = title_override.to_s.presence
    @setting = user.invoice_setting_for(@category || "wings")
    @issuer_setting = @issuer_user.invoice_setting_for(@category || "wings")
    # 集約モード: 同じ PO の複数申請（例: ORD-010014 の西野+川村）を 1 PDF にまとめる
    @merged_users = Array(merged_users).reject { |u| u.id == user.id }
  end

  # データ計算結果をハッシュで返す（JSON プレビュー API でも使用）
  #
  # 計算ルール（税抜統一）:
  # - すべての明細 unit_price / amount は **税抜** で扱う（DB 登録もこれに合わせる）
  # - subtotal = items の amount 合計（税抜）
  # - tax = subtotal × tax_rate / 100（四捨五入）
  # - total = subtotal + tax（税込）
  # - @total_override が指定された場合のみ、税込合計として上書きし subtotal/tax を逆算
  def calculation
    period = @user.period_for(@year, @month)
    scope = @user.work_reports.in_range(period)
    scope = scope.by_category(@category) if @category.present?
    hours = scope.sum(:hours).to_f
    items = build_items(hours)

    rate = labop_mode? ? 10 : @setting.tax_rate.to_i
    subtotal = items.sum { |i| i[:amount] }
    tax = (subtotal * rate / 100.0).round
    total = subtotal + tax

    # @total_override は「税込合計」として最優先（admin がラボップモーダルで明示した値）
    if @total_override
      total = @total_override.to_i
      subtotal = (total / (1.0 + rate / 100.0)).round
      tax = total - subtotal
      # 明細が無い labop モードのみ、override に合わせて単一行を再生成（unit_price=3,750 円/時間）
      # 自己発行(非labop)は時給概念が無いカテゴリ(resystems 等)があるので、勝手な時給行を作らない。
      if items.empty? && labop_mode?
        unit_price = InvoiceSetting.default_unit_price_for(@category || "wings").nonzero? || 3_750
        qty_f = subtotal.to_f / unit_price
        qty = qty_f == qty_f.to_i ? qty_f.to_i : qty_f.round(1)
        items = [ { label: build_default_label, qty: qty, unit: "時間", unit_price: unit_price, amount: subtotal } ]
      end
    end

    issue_date = period.last
    due_date = @due_date_override.presence || calc_due_date(issue_date)
    invoice_no = "#{issue_date.strftime('%Y%m%d')}#{format('%04d', @user.id)}"
    # 申請日: 発行者(issuer)の monthly_settings を優先（西野が川村の請求書を発行する場合は西野の末日設定）
    application_date = @application_date || @issuer_user.application_date_for(@year, @month) || @user.application_date_for(@year, @month)

    {
      period: { from: period.first, to: period.last },
      hours: hours,
      items: items,
      subtotal: subtotal,
      tax_rate: labop_mode? ? 10 : @setting.tax_rate,
      tax: tax,
      total: total,
      issue_date: issue_date,
      due_date: due_date,
      invoice_no: invoice_no,
      application_date: application_date
    }
  end

  def labop_mode?
    @issuer_user && @issuer_user != @user
  end

  def call
    data = calculation
    setting = @setting
    user = @user
    issuer_user = @issuer_user
    issuer_setting = @issuer_setting
    # 宛先 (client_name) と敬称 (honorific) の決定:
    # - client_name_override が明示指定: その値を優先（ラボップなら御中、それ以外は人名扱いで様）
    # - 指定なしの通常モード: User#invoice_recipient_name に従う（admin=ラボップ御中 / 非admin=admin宛様）
    # - 指定なしの labop モード: setting からフォールバック
    labop_name = I18n.t("companies.labop.name")
    if @client_name_override.present?
      client_name = @client_name_override
      honorific = (client_name == labop_name) ? "御中" : "様"
    elsif !labop_mode?
      # カテゴリ別の宛先設定 (resystems=株式会社ReReシステムズ / techleaders 等) があれば最優先。
      # 設定が空のときだけユーザー既定の宛先 (admin=株式会社ラボップ) にフォールバックする。
      # これが無いと admin の自己発行請求書は全カテゴリで宛先がラボップ固定になってしまう。
      if setting.client_name.present?
        client_name = setting.client_name
        honorific = setting.honorific.presence || "御中"
      else
        client_name = @user.invoice_recipient_name
        honorific = @user.invoice_recipient_honorific
      end
    else
      client_name = setting.client_name
      honorific = setting.honorific.presence || "御中"
    end
    subject_text = @subject_override || setting.subject.to_s
    # category=living は件名を固定: 「タマリビング様 システム保守・開発」
    # （DB に重複文字が保存されていても、新規生成時に必ず正しい形にする）
    if @category == "living"
      subject_text = "タマリビング様 システム保守・開発"
    end

    # シェアラウンジ請求書の宛名固定: 件名/備考に「シェアラウンジ」を含むなら宛名は必ず「株式会社ラボップ」
    # 「大隅様」だと経費精算に通らないため
    if subject_text.to_s.include?("シェアラウンジ") || @note.to_s.include?("シェアラウンジ")
      client_name = I18n.t("companies.labop.name")
      honorific = "御中"
    end

    note_text = @note  # 備考に出すテキスト（発注番号、シェアラウンジ補足等）
    title_text = @title_override || "請求書"
    registration_no_override = @registration_no_override  # インボイス番号の請求書単体上書き(ERBで使用)
    bank_info_text = @bank_info_override || setting.bank_info  # 振込先: 請求書単体の上書き優先、無ければ設定値(ERBで使用)

    html_body = ERB.new(File.read(TEMPLATE)).result(binding)

    out_dir = Rails.root.join("tmp/exports")
    FileUtils.mkdir_p(out_dir)
    html_path = out_dir.join("invoice_#{user.id}_#{@year}_#{@month}_#{SecureRandom.hex(4)}.html").to_s
    pdf_path  = html_path.sub(/\.html$/, ".pdf")
    File.write(html_path, html_body)

    out, err, status = Open3.capture3("node", SCRIPT.to_s, html_path, pdf_path)
    raise "html_to_pdf failed: #{err}" unless status.success?

    pdf_path
  ensure
    File.delete(html_path) if defined?(html_path) && html_path && File.exist?(html_path)
  end

  private

  # 明細(items)構築。すべて **税抜単価** で返す。
  # - labop モード + items_override 指定時: その明細をそのまま使う
  # - labop モード + items_override なし & merged_users なし: total_override から逆算 → 空配列
  # - merged_users あり: 各ユーザーの設定で行を生成して連結（ORD-010014 西野+川村 等）
  # - 通常モード: setting.unit_price (時間単価) + setting.default_items から組み立て
  # 複数ユーザー集約 or 発行者≠申請者の labop モードでは、作業者名を品名先頭に付与
  def build_items(hours)
    # アプリ内編集で保存した明細 (items_override) は labop / 自己発行に関係なく最優先で使う。
    # これが無いと自己発行請求書で編集が PDF に反映されず、時給行が勝手に再生成されてしまう。
    if @items_override
      return @items_override.map do |it|
        h = it.respond_to?(:to_h) ? it.to_h : it
        {
          label: (h[:label] || h["label"]).to_s,
          qty: (h[:qty] || h["qty"]).to_f,
          unit: (h[:unit] || h["unit"]).to_s.presence || "式",
          unit_price: (h[:unit_price] || h["unit_price"]).to_i,
          amount: (h[:amount] || h["amount"]).to_i
        }
      end
    end

    # labop モード + items_override なし + merged_users なし → calculation 側で total_override から逆算
    return [] if labop_mode? && @merged_users.empty?

    # 集約モード判定
    target_users = [ @user, *@merged_users ].uniq
    multi_user = target_users.size > 1
    items = []

    target_users.each do |u|
      u_period = u.period_for(@year, @month)
      u_scope = u.work_reports.in_range(u_period)
      u_scope = u_scope.by_category(@category) if @category.present?
      u_hours = u_scope.sum(:hours).to_f
      u_setting = u.invoice_setting_for(@category || "wings")
      # 動的紐付け: 該当月の billing period (u_period) が PurchaseOrderSetting の period と重なれば
      # その PO の rate_per_hour を時給として優先採用（4-5月分は旧 PO の rate、6月以降は新 PO の rate が自動で当たる）
      # 重なる PO が複数あれば period_start が最新のものを採用、なければ invoice_settings.unit_price に fallback
      matched_po = PurchaseOrderSetting
        .where(recipient_user_id: u.id, category: (@category || "wings"))
        .where("period_start IS NULL OR period_start <= ?", u_period.last)
        .where("period_end   IS NULL OR period_end   >= ?", u_period.first)
        .order(period_start: :desc).first
      # 時給: ①対応する注文書(PO)の rate_per_hour を最優先 → ②カテゴリ別デフォルト(living=3750/wings=3500)。
      # 人別に保存された unit_price はフォールバックには使わない（カテゴリで一律にする方針）。
      effective_unit_price = (matched_po&.rate_per_hour.to_i.nonzero?) || InvoiceSetting.default_unit_price_for(@category || "wings")
      name_prefix = u.display_name.to_s.strip
      name_prefix = name_prefix.empty? ? "" : "#{name_prefix} "

      if effective_unit_price > 0
        items << {
          label: "#{name_prefix}#{u_setting.item_label}(#{format('%.1f', u_hours)}hまで)",
          qty: u_hours,
          unit: "時間",
          unit_price: effective_unit_price,
          amount: (u_hours * effective_unit_price).to_i # 税抜
        }
      end

      Array(u_setting.default_items).each do |it|
        qty = (it["qty"] || it[:qty] || 1).to_f
        price = (it["price"] || it[:price] || 0).to_i # 税抜単価
        raw_label = (it["label"] || it[:label]).to_s
        # multi_user 時は必ず prefix、単一ユーザーは既に入っていれば省略
        label = if multi_user
                  raw_label.start_with?(name_prefix) ? raw_label : "#{name_prefix}#{raw_label}"
        else
                  raw_label.start_with?(name_prefix) ? raw_label : "#{name_prefix}#{raw_label}"
        end
        items << {
          label: label,
          qty: qty,
          unit: it["unit"] || it[:unit] || "",
          unit_price: price,
          amount: (qty * price).to_i # 税抜
        }
      end
    end
    items
  end

  def build_default_label
    full_name = @user.display_name.to_s.strip
    base = full_name.empty? ? "開発業務" : "#{full_name} 開発業務"
    @item_label_override.presence || base
  end

  # 支払期限を計算
  # payment_due_type:
  #   "days_N"       → 発行日 + N日（従来互換）
  #   "next_month_end" → 来月末日
  #   "next_next_month_end" → 再来月末日
  #   "month_end"    → 当月末日
  #   nil/空         → 従来の payment_due_days で計算
  def calc_due_date(issue_date)
    # 発行者(issuer)の設定を優先（西野が川村のラボップ宛を発行する場合は西野の設定）
    setting = @issuer_setting || @setting
    due_type = setting.respond_to?(:payment_due_type) ? setting.payment_due_type : nil

    case due_type
    when "next_month_end"
      next_month = issue_date >> 1
      Date.new(next_month.year, next_month.month, -1)
    when "next_next_month_end"
      m = issue_date >> 2
      Date.new(m.year, m.month, -1)
    when "month_end"
      Date.new(issue_date.year, issue_date.month, -1)
    when /\Adays_(\d+)\z/
      issue_date + $1.to_i
    else
      # デフォルトを「翌月末日」に変更（payment_due_days 35 だと末日にならないケース対策）
      due_days = setting.respond_to?(:payment_due_days) ? setting.payment_due_days : nil
      if due_days.present?
        issue_date + due_days
      else
        next_month = issue_date >> 1
        Date.new(next_month.year, next_month.month, -1)
      end
    end
  end
end
