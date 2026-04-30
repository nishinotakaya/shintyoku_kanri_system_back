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
                 items_override: nil)
    @user = user
    @year = year
    @month = month
    @category = category
    @application_date = application_date
    @client_name_override = client_name_override.presence
    @issuer_user = issuer_user_override || user
    @total_override = total_override.to_i if total_override.present?
    @item_label_override = item_label_override.to_s.presence
    @subject_override = subject_override.to_s.presence
    @items_override = items_override if items_override.is_a?(Array) && items_override.any?
    @setting = user.invoice_setting_for(@category || "wings")
    @issuer_setting = @issuer_user.invoice_setting_for(@category || "wings")
  end

  # データ計算結果をハッシュで返す（JSON プレビュー API でも使用）
  def calculation
    period = @user.period_for(@year, @month)
    scope = @user.work_reports.in_range(period)
    scope = scope.by_category(@category) if @category.present?
    hours = scope.sum(:hours).to_f
    items = []

    if @setting.unit_price.to_i > 0
      items << {
        label: "#{@setting.item_label}(#{format('%.1f', hours)}hまで)",
        qty: hours,
        unit: "時間",
        unit_price: @setting.unit_price,
        amount: (hours * @setting.unit_price).to_i
      }
    end

    Array(@setting.default_items).each do |it|
      qty = (it["qty"] || it[:qty] || 1).to_f
      price = (it["price"] || it[:price] || 0).to_i
      items << {
        label: it["label"] || it[:label],
        qty: qty,
        unit: it["unit"] || it[:unit] || "",
        unit_price: price,
        amount: (qty * price).to_i
      }
    end

    subtotal = items.sum { |i| i[:amount] }
    tax = (subtotal * @setting.tax_rate / 100.0).round
    total = subtotal + tax

    # ラボップ宛 (issuer override) モード:
    # items_override が指定されていればその明細をそのまま使い、合計は明細から自動算出。
    # 指定が無ければ「{申請者の姓} 開発業務 1式」1行を生成して total_override で上書き。
    # 消費税は 10% 内税扱い (subtotal = round(total/1.1), tax = total - subtotal)。
    if labop_mode?
      if @items_override
        items = @items_override.map do |it|
          h = it.respond_to?(:to_h) ? it.to_h : it
          {
            label: (h[:label] || h["label"]).to_s,
            qty: (h[:qty] || h["qty"]).to_f,
            unit: (h[:unit] || h["unit"]).to_s.presence || "式",
            unit_price: (h[:unit_price] || h["unit_price"]).to_i,
            amount: (h[:amount] || h["amount"]).to_i
          }
        end
        total = @total_override || items.sum { |i| i[:amount] }
      else
        full_name = @user.display_name.to_s.strip
        default_label = full_name.empty? ? "開発業務" : "#{full_name} 開発業務"
        label = @item_label_override || default_label
        total = @total_override || total
        subtotal_tmp = (total / 1.1).round
        # 単価 3,750 円/時間 で割って数量を出す。割り切れない場合は小数 1 桁。
        unit_price = 3_750
        qty = subtotal_tmp.to_f / unit_price
        qty = qty == qty.to_i ? qty.to_i : qty.round(1)
        items = [ { label: label, qty: qty, unit: "時間", unit_price: unit_price, amount: subtotal_tmp } ]
      end
      subtotal = (total / 1.1).round
      tax = total - subtotal
    end

    issue_date = period.last
    due_date = calc_due_date(issue_date)
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
    client_name = @client_name_override || setting.client_name
    subject_text = @subject_override || setting.subject.to_s
    # category=living で件名に「リビング」が無い場合は補完
    if @category == "living" && !subject_text.include?("リビング")
      subject_text = subject_text.empty? ? "リビング システム保守・開発" : "リビング システム保守・開発 #{subject_text}".strip
    end

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
