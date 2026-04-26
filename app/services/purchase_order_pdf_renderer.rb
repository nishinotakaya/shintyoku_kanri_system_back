require "open3"
require "fileutils"
require "erb"

# 発注書 PDF を生成。
# フォーム入力（宛先・明細・備考など）を受け取り、HTML → PDF に変換。
class PurchaseOrderPdfRenderer
  TEMPLATE = Rails.root.join("app/views/invoices/purchase_order.html.erb")
  SCRIPT   = Rails.root.join("lib/exporters/html_to_pdf.mjs")

  def initialize(user, params)
    @user = user
    @params = params
  end

  def call
    raise "発注権限がありません" unless @user.can_issue_orders

    items = parse_items(@params[:items])
    subtotal = items.sum { |it| it[:amount].to_i }
    tax_rate = (@params[:tax_rate] || 10).to_f / 100.0
    tax = (subtotal * tax_rate).round
    total = subtotal + tax

    data = {
      order_date:     format_date(@params[:order_date]) || Date.current.iso8601,
      order_no:       @params[:order_no].to_s.presence || generate_order_no,
      subject:        @params[:subject].to_s,
      recipient:      {
        name:         @params.dig(:recipient, :name).to_s,
        postal_code:  @params.dig(:recipient, :postal_code).to_s,
        address:      @params.dig(:recipient, :address).to_s
      },
      issuer: {
        company_name:   @params.dig(:issuer, :company_name).presence || @user.company_name.to_s,
        representative: @params.dig(:issuer, :representative).presence || @user.display_name.to_s,
        postal_code:    postal_with_prefix(@params.dig(:issuer, :postal_code).presence || @user.postal_code),
        address:        @params.dig(:issuer, :address).presence || @user.address.to_s
      },
      items: items,
      subtotal: subtotal,
      tax: tax,
      total: total,
      delivery_deadline: @params[:delivery_deadline].to_s,
      delivery_location: @params[:delivery_location].to_s.presence || "客先指定場所",
      payment_method:    @params[:payment_method].to_s.presence || "振込",
      remarks:           @params[:remarks].to_s
    }

    html_body = ERB.new(File.read(TEMPLATE)).result_with_hash(data: data)

    out_dir = Rails.root.join("tmp/exports")
    FileUtils.mkdir_p(out_dir)
    stamp = SecureRandom.hex(4)
    html_path = out_dir.join("purchase_order_#{@user.id}_#{stamp}.html").to_s
    pdf_path  = html_path.sub(/\.html$/, ".pdf")
    File.write(html_path, html_body)

    _, err, status = Open3.capture3("node", SCRIPT.to_s, html_path, pdf_path)
    raise "html_to_pdf failed: #{err}" unless status.success?
    pdf_path
  ensure
    File.delete(html_path) if defined?(html_path) && html_path && File.exist?(html_path)
  end

  private

  def parse_items(raw)
    return [] if raw.blank?
    raw.map do |it|
      qty_raw    = it[:qty]
      unit       = it[:unit].to_s
      unit_price = it[:unit_price].to_i
      qty_num    = qty_raw.to_f
      amount     = (qty_num * unit_price).round
      qty_str    = qty_num.zero? ? "" : (qty_num == qty_num.to_i ? qty_num.to_i.to_s : qty_num.to_s)
      display    = qty_str.empty? ? "" : (unit.empty? ? qty_str : "#{qty_str} #{unit}")
      { description: it[:description].to_s, qty: display, unit_price: unit_price, amount: amount }
    end
  end

  def format_date(str)
    return nil if str.blank?
    Date.iso8601(str).iso8601
  rescue ArgumentError
    str.to_s
  end

  def postal_with_prefix(code)
    c = code.to_s.strip
    return "" if c.empty?
    c.start_with?("〒") ? c : "〒#{c}"
  end

  def generate_order_no
    seq = (Time.current.to_i % 1_000_000).to_s.rjust(6, "0")
    "ORD-#{seq}"
  end
end
