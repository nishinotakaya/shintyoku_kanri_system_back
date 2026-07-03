require "erb"
require "open3"
require "base64"

# 国税庁の白紙様式(実物)に値を重ね打ちして「提出書類と同じ見た目」のPDFを作る。
# kind:
#   :kessansho   青色申告決算書(一般用) P1損益計算書 / P2月別売上・特別控除 / P3減価償却・売上明細 (A4横)
#   :shinkokusho 確定申告書 第一表 (A4縦)
class OfficialTaxFormRenderer
  TEMPLATE = Rails.root.join("app/views/invoices/tax_form_overlay.html.erb")
  SCRIPT   = Rails.root.join("lib/exporters/html_to_pdf.mjs")
  FORMS    = Rails.root.join("app/reports/tax_forms")

  # 決算書P1: 固定科目→科目番号(枠は様式に印字済み)
  FIXED_CATEGORIES = {
    "租税公課" => 8, "荷造運賃" => 9, "水道光熱費" => 10, "旅費交通費" => 11, "通信費" => 12,
    "広告宣伝費" => 13, "接待交際費" => 14, "損害保険料" => 15, "修繕費" => 16,
    "消耗品費" => 17, "減価償却費" => 18, "福利厚生費" => 19, "給料賃金" => 20, "外注工賃" => 21,
    "利子割引料" => 22, "地代家賃" => 23, "貸倒金" => 24
  }.freeze

  def initialize(user, year:, deduction: 650_000)
    @user = user
    @year = year
    @deduction = deduction.to_i
    @summary = TaxSummaryBuilder.call(user, year)
    @assets = user.fixed_assets.order(:acquired_on).to_a
    @setting = user.invoice_setting_for("wings")
  end

  def render_kessansho
    render_pdf(kessansho_pages, orientation: "landscape")
  end

  def render_shinkokusho
    render_pdf([ shinkokusho_page ], orientation: "full")
  end

  # === 集計値 ===
  def profit_before_deduction = @summary[:profit]
  def deduction_applied = [ [ profit_before_deduction, 0 ].max, @deduction ].min
  def final_income = profit_before_deduction - deduction_applied

  private

  def render_pdf(pages, orientation:)
    html_body = ERB.new(File.read(TEMPLATE)).result(binding)
    out_dir = Rails.root.join("tmp/exports")
    FileUtils.mkdir_p(out_dir)
    html_path = out_dir.join("taxform_#{@user.id}_#{SecureRandom.hex(4)}.html").to_s
    pdf_path = html_path.sub(/\.html$/, ".pdf")
    File.write(html_path, html_body)
    _out, err, status = Open3.capture3("node", SCRIPT.to_s, html_path, pdf_path, orientation)
    raise "html_to_pdf failed: #{err}" unless status.success?
    pdf_path
  ensure
    File.delete(html_path) if defined?(html_path) && html_path && File.exist?(html_path)
  end

  def form_base64(name) = Base64.strict_encode64(File.binread(FORMS.join(name)))
  def fmt(n) = n.to_i.zero? ? "" : n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  def fmt0(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  def wareki = @year - 2018

  def category_totals
    @summary[:by_category].to_h { |row| [ row[:category], row[:total] ] }
  end

  # 決算書に固定枠が無いアプリ科目(会議費/新聞図書費/支払手数料/車両費/未分類) → 空欄枠㉕〜㉚
  def extra_categories
    @summary[:by_category].reject { |row| FIXED_CATEGORIES.key?(row[:category]) || row[:category] == "雑費" }
  end

  # ============ 決算書 P1: 損益計算書 ============
  def kessansho_pages
    [ kessansho_p1, kessansho_p2, kessansho_p3 ]
  end

  def kessansho_p1
    totals = category_totals
    f = []
    # ヘッダー
    f << { x: 40.35, y: 7.9, text: wareki.to_s, size: 12 }
    f << { x: 40.5, y: 12.5, text: @setting&.address.to_s, size: 8 }
    f << { x: 63.5, y: 13.3, text: @user.display_name.to_s, size: 11 }
    f << { x: 40.5, y: 23.2, text: "ソフトウェア・情報サービス業", size: 9 }
    f << { x: 66.3, y: 18.6, text: @setting&.tel.to_s, size: 9 }
    # 自1月1日 至12月31日
    f << { x: 57.6, y: 31.0, text: "1", size: 10 }
    f << { x: 62.2, y: 31.0, text: "1", size: 10 }
    f << { x: 66.6, y: 31.0, text: "12", size: 10 }
    f << { x: 71.2, y: 31.0, text: "31", size: 10 }

    # 左列 金額 (右端 x=20.5〜35.3 の右寄せ)
    lx, lw = 20.5, 14.6
    f << { x: lx, y: 39.7, w: lw, align: :right, text: fmt(@summary[:income_total]), size: 11 }
    f << { x: lx, y: 59.3, w: lw, align: :right, text: fmt(@summary[:income_total]), size: 11 }  # ⑦
    { 8 => 64.7, 9 => 67.65, 10 => 70.6, 11 => 73.55, 12 => 76.5, 13 => 79.45, 14 => 82.4, 15 => 85.35, 16 => 88.3 }.each do |no, y|
      cat = FIXED_CATEGORIES.key(no)
      f << { x: lx, y: y, w: lw, align: :right, text: fmt(totals[cat]), size: 10 }
    end

    # 中列 金額 (x=48.0〜63.7 右寄せ)
    mx, mw = 47.5, 15.0
    { 17 => 38.9, 18 => 41.77, 19 => 44.64, 20 => 47.51, 21 => 50.38, 22 => 53.25, 23 => 56.12, 24 => 58.99 }.each do |no, y|
      cat = FIXED_CATEGORIES.key(no)
      f << { x: mx, y: y, w: mw, align: :right, text: fmt(totals[cat]), size: 10 }
    end
    # 空欄枠 ㉕〜㉚ (科目名 + 金額)
    slot_ys = [ 62.0, 64.87, 67.74, 70.61, 73.48, 76.35 ]
    extra_categories.first(6).each_with_index do |row, i|
      f << { x: 38.5, y: slot_ys[i], text: row[:category], size: 9 }
      f << { x: mx, y: slot_ys[i], w: mw, align: :right, text: fmt(row[:total]), size: 10 }
    end
    f << { x: mx, y: 79.3, w: mw, align: :right, text: fmt(category_totals["雑費"]), size: 10 }             # ㉛
    f << { x: mx, y: 82.3, w: mw, align: :right, text: fmt0(@summary[:expense_total]), size: 10 }          # ㉜ 計
    f << { x: mx, y: 86.4, w: mw, align: :right, text: fmt0(profit_before_deduction), size: 11 }           # ㉝

    # 右列 ㊸㊹㊺ (x=76.7〜92.0 右寄せ)
    rx, rw = 76.7, 15.0
    f << { x: rx, y: 63.9, w: rw, align: :right, text: fmt0(profit_before_deduction), size: 11 }
    f << { x: rx, y: 67.9, w: rw, align: :right, text: fmt0(deduction_applied), size: 11 }
    f << { x: rx, y: 71.9, w: rw, align: :right, text: fmt0(final_income), size: 12 }

    { image_base64: form_base64("kessansho_p1.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # ============ 決算書 P2: 月別売上 + 青色申告特別控除の計算 ============
  def kessansho_p2
    f = []
    f << { x: 13.3, y: 5.8, text: wareki.to_s, size: 12 }
    f << { x: 21.0, y: 9.2, text: @user.display_name.to_s, size: 10 }
    # 月別売上 (1〜12月): 金額右寄せ x=13.0〜28.5
    sx, sw = 13.0, 15.0
    row0, row_h = 19.05, 3.05
    @summary[:monthly].each_with_index do |m, i|
      f << { x: sx, y: row0 + row_h * i, w: sw, align: :right, text: fmt(m[:income]), size: 10 }
    end
    f << { x: sx, y: 62.0, w: sw, align: :right, text: fmt0(@summary[:income_total]), size: 11 } # 計
    # 青色申告特別控除の計算 (右下): ⑦控除前所得 / ⑨控除額
    f << { x: 77.5, y: 80.4, w: 13.0, align: :right, text: fmt0(profit_before_deduction), size: 10 }
    f << { x: 77.5, y: 85.2, w: 13.0, align: :right, text: fmt0(deduction_applied), size: 10 }
    { image_base64: form_base64("kessansho_p2.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # ============ 決算書 P3: 売上明細 + 減価償却費の計算 ============
  def kessansho_p3
    f = []
    # 売上(収入)金額の明細: 上記以外の計 / 計
    f << { x: 57.0, y: 21.3, w: 11.5, align: :right, text: fmt0(@summary[:income_total]), size: 10 }
    f << { x: 57.0, y: 24.6, w: 11.5, align: :right, text: fmt0(@summary[:income_total]), size: 10 }
    # 減価償却費の計算 (資産ごと)
    row0, row_h = 57.7, 4.0
    @assets.first(7).each_with_index do |a, i|
      y = row0 + row_h * i
      annual = (a.cost / a.useful_life_years.to_f).floor
      months = a.acquired_on.year == @year ? (13 - a.acquired_on.month) : 12
      raw = @year < a.acquired_on.year ? 0 : (annual * months / 12.0).floor
      dep = a.depreciation_for(@year)
      f << { x: 3.2, y: y, text: a.name.to_s.slice(0, 10), size: 8 }
      f << { x: 10.2, y: y, text: "#{a.acquired_on.year % 100}・#{a.acquired_on.month}", size: 8 }
      f << { x: 14.5, y: y, w: 8.0, align: :right, text: fmt0(a.cost), size: 8 }
      f << { x: 24.0, y: y, w: 8.5, align: :right, text: fmt0(a.cost), size: 8 }
      f << { x: 33.0, y: y, text: "定額", size: 8 }
      f << { x: 37.8, y: y, text: a.useful_life_years.to_s, size: 8 }
      f << { x: 40.0, y: y, text: format("%.3f", 1.0 / a.useful_life_years), size: 8 }
      f << { x: 44.3, y: y, text: "#{months}/12", size: 8 }
      f << { x: 47.5, y: y, w: 7.5, align: :right, text: fmt0(raw), size: 8 }
      f << { x: 59.5, y: y, w: 6.5, align: :right, text: fmt0(raw), size: 8 }
      f << { x: 67.8, y: y, text: a.business_ratio.to_s, size: 8 }
      f << { x: 71.5, y: y, w: 7.5, align: :right, text: fmt0(dep), size: 8 }
    end
    if @assets.any?
      f << { x: 47.5, y: 84.5, w: 7.5, align: :right, text: fmt0(@summary[:depreciation_total]), size: 8 }
      f << { x: 71.5, y: 84.5, w: 7.5, align: :right, text: fmt0(@summary[:depreciation_total]), size: 8 }
    end
    { image_base64: form_base64("kessansho_p3.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # ============ 確定申告書 第一表 ============
  # 様式は令和六年分用(FA2204)。行番号は同様式に準拠: (30)課税所得 (31)税額 (41)差引 (43)再差引
  # (46)復興特別所得税 (47)合計 (51)申告納税額 (53)第3期分納める税金 (60)青色申告特別控除額
  def shinkokusho_page
    f = []
    f << { x: 12.0, y: 9.0, text: @setting&.address.to_s, size: 8 }
    f << { x: 48.0, y: 12.1, text: @user.display_name.to_s, size: 11 }
    f << { x: 40.5, y: 14.3, text: "ソフトウェア・情報サービス業", size: 7 }

    income = @summary[:income_total]
    basic_deduction = 680_000 # 基礎控除
    taxable = [ ((final_income - basic_deduction) / 1000) * 1000, 0 ].max
    tax = income_tax_for(taxable)
    reconstruction = (tax * 0.021).floor
    total_tax = tax + reconstruction
    payment = (total_tax / 100) * 100

    money = ->(y, v, size = 10) { { x: 21.0, y: y, w: 15.5, align: :right, text: fmt0(v), size: size } }
    f << money.call(20.0, income)                      # 収入 事業営業等(ア)
    f << money.call(42.9, final_income)                # 所得 事業①
    f << money.call(64.0, final_income)                # ⑫合計
    f << money.call(82.7, basic_deduction)             # ㉔基礎控除
    f << money.call(85.7, basic_deduction)             # ㉕13から24までの計
    rmoney = ->(y, v, size = 10) { { x: 58.5, y: y, w: 15.0, align: :right, text: fmt0(v), size: size } }
    # (30)課税所得は下3桁000がプレ印字 → 千円単位のみ刻印
    f << { x: 58.5, y: 20.3, w: 11.7, align: :right, text: fmt0(taxable / 1000), size: 10 }
    f << rmoney.call(23.0, tax)                        # (31)税額
    f << rmoney.call(33.8, tax)                        # (41)差引所得税額
    f << rmoney.call(38.2, tax)                        # (43)再差引所得税額
    f << rmoney.call(44.4, reconstruction)             # (46)復興特別所得税額
    f << rmoney.call(46.7, total_tax)                  # (47)所得税及び復興特別所得税の額
    f << rmoney.call(54.3, payment)                    # (51)申告納税額
    # (53)納める税金は下2桁00がプレ印字 → 百円単位のみ刻印
    f << { x: 58.5, y: 58.9, w: 12.3, align: :right, text: fmt0(payment / 100), size: 10 }
    f << rmoney.call(69.3, deduction_applied)          # (60)青色申告特別控除額
    { image_base64: form_base64("shinkokusho_p1.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # 所得税の速算表 (令和方式)
  def income_tax_for(taxable)
    brackets = [
      [ 1_949_000, 0.05, 0 ],
      [ 3_299_000, 0.10, 97_500 ],
      [ 6_949_000, 0.20, 427_500 ],
      [ 8_999_000, 0.23, 636_000 ],
      [ 17_999_000, 0.33, 1_536_000 ],
      [ 39_999_000, 0.40, 2_796_000 ],
      [ Float::INFINITY, 0.45, 4_796_000 ]
    ]
    rate, deduct = brackets.find { |limit, _, _| taxable <= limit }.then { |_, r, d| [ r, d ] }
    [ (taxable * rate - deduct).floor, 0 ].max
  end
end
