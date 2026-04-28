require "open3"
require "fileutils"
require "erb"

# 月次の業務報告から請求金額を計算し、HTML を生成して
# Playwright Chromium で PDF に変換する。
class InvoicePdfRenderer
  TEMPLATE = Rails.root.join("app/views/invoices/invoice.html.erb")
  SCRIPT   = Rails.root.join("lib/exporters/html_to_pdf.mjs")

  def initialize(user, year:, month:, category: nil, application_date: nil, client_name_override: nil)
    @user = user
    @year = year
    @month = month
    @category = category
    @application_date = application_date
    @client_name_override = client_name_override.presence
    @setting = user.invoice_setting_for(@category || "wings")
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

    issue_date = period.last
    due_date = calc_due_date(issue_date)
    invoice_no = "#{issue_date.strftime('%Y%m%d')}#{format('%04d', @user.id)}"
    application_date = @application_date || @user.application_date_for(@year, @month)

    {
      period: { from: period.first, to: period.last },
      hours: hours,
      items: items,
      subtotal: subtotal,
      tax_rate: @setting.tax_rate,
      tax: tax,
      total: total,
      issue_date: issue_date,
      due_date: due_date,
      invoice_no: invoice_no,
      application_date: application_date
    }
  end

  def call
    data = calculation
    setting = @setting
    user = @user
    client_name = @client_name_override || setting.client_name

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
    due_type = @setting.respond_to?(:payment_due_type) ? @setting.payment_due_type : nil

    case due_type
    when "next_month_end"
      # 来月末日
      next_month = issue_date >> 1
      Date.new(next_month.year, next_month.month, -1)
    when "next_next_month_end"
      # 再来月末日
      m = issue_date >> 2
      Date.new(m.year, m.month, -1)
    when "month_end"
      # 当月末日
      Date.new(issue_date.year, issue_date.month, -1)
    when /\Adays_(\d+)\z/
      issue_date + $1.to_i
    else
      issue_date + (@setting.payment_due_days || 35)
    end
  end
end
