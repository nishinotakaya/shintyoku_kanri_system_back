require "erb"
require "open3"

# 青色申告決算書(損益計算書)の様式風PDFを生成する（転記・保管用）。
# 科目番号は実物(FA3001)に準拠: ①売上 ⑧租税公課〜㉔貸倒金 ㉕〜㉚空欄枠 ㉛雑費 ㉜計 ㉝差引 ㊸㊹㊺。
class TaxReturnPdfRenderer
  TEMPLATE = Rails.root.join("app/views/invoices/blue_return.html.erb")
  SCRIPT   = Rails.root.join("lib/exporters/html_to_pdf.mjs")

  # 決算書の固定科目(番号順)。ここに無いアプリ科目(会議費等)は空欄枠㉕〜㉚に入る。
  FIXED_CATEGORIES = {
    "租税公課" => 8, "荷造運賃" => 9, "水道光熱費" => 10, "旅費交通費" => 11, "通信費" => 12,
    "広告宣伝費" => 13, "接待交際費" => 14, "損害保険料" => 15, "修繕費" => 16, "消耗品費" => 17,
    "減価償却費" => 18, "福利厚生費" => 19, "給料賃金" => 20, "外注工賃" => 21, "利子割引料" => 22,
    "地代家賃" => 23, "貸倒金" => 24
  }.freeze
  FREE_SLOT_NUMBERS = (25..30).to_a.freeze # 空欄枠

  def initialize(user, year:, deduction: 650_000)
    @user = user
    @year = year
    @deduction = deduction.to_i
    @summary = TaxSummaryBuilder.call(user, year)
    @setting = user.invoice_setting_for("wings")
  end

  def call
    html_body = ERB.new(File.read(TEMPLATE)).result(binding)
    out_dir = Rails.root.join("tmp/exports")
    FileUtils.mkdir_p(out_dir)
    html_path = out_dir.join("blue_return_#{@user.id}_#{@year}_#{SecureRandom.hex(4)}.html").to_s
    pdf_path = html_path.sub(/\.html$/, ".pdf")
    File.write(html_path, html_body)
    _out, err, status = Open3.capture3("node", SCRIPT.to_s, html_path, pdf_path)
    raise "html_to_pdf failed: #{err}" unless status.success?
    pdf_path
  ensure
    File.delete(html_path) if defined?(html_path) && html_path && File.exist?(html_path)
  end

  private

  # === ERB から参照するヘルパー ===

  def fmt(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse.sub(/^(-?)\,?/) { $1 }

  def wareki_year = @year - 2018 # 令和(2019=元年)

  def year = @year
  def name = @user.display_name.to_s
  def address = @setting&.address.to_s
  def tel = @setting&.tel.to_s
  def industry = "ソフトウェア・情報サービス業"
  def monthly = @summary[:monthly]
  def income_total = @summary[:income_total]
  def expense_total = @summary[:expense_total]
  def assets_count = @user.fixed_assets.count
  def generated_at = Time.current.strftime("%Y-%m-%d %H:%M")

  def profit_before_deduction = @summary[:profit]
  # 青色申告特別控除は所得金額が上限（マイナスなら0）
  def deduction_applied = [ [ profit_before_deduction, 0 ].max, @deduction ].min
  def final_income = profit_before_deduction - deduction_applied

  # 損益計算書の行(科目番号つき)を実物の並びで組み立てる
  def pl_rows
    totals = @summary[:by_category].to_h { |row| [ row[:category], row[:total] ] }
    rows = []
    rows << { no: 1, label: "売上(収入)金額", amount: income_total, strong: true }
    rows << { no: 7, label: "差引金額(①−⑥)", amount: income_total, strong: false }

    FIXED_CATEGORIES.each do |category, number|
      rows << { no: number, label: category, amount: totals[category] }
    end

    # 決算書に無いアプリ科目(会議費・新聞図書費・支払手数料・車両費・未分類)は空欄枠㉕〜㉚へ
    extra = @summary[:by_category].reject { |row| FIXED_CATEGORIES.key?(row[:category]) || row[:category] == "雑費" }
    extra.first(FREE_SLOT_NUMBERS.size).each_with_index do |row, i|
      rows << { no: FREE_SLOT_NUMBERS[i], label: row[:category], amount: row[:total] }
    end
    (extra.size...FREE_SLOT_NUMBERS.size).each { |i| rows << { no: FREE_SLOT_NUMBERS[i], label: "", amount: nil } }

    rows << { no: 31, label: "雑費", amount: totals["雑費"] }
    rows << { no: 32, label: "経費 計", amount: expense_total, strong: true }
    rows << { no: 33, label: "差引金額(⑦−㉜)", amount: profit_before_deduction, strong: true }
    rows
  end
end
