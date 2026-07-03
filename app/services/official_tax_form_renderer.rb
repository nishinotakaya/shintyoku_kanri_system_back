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

  # 消費税及び地方消費税申告書(2割特例): 第一表(GK0306)/第二表(GK0602)/付表6
  # 様式は本人の提出済みPDFをテンプレ化(数値のみ差し替え)。○2割特例・氏名・納税地は様式に印字済み。
  def render_shohi
    render_pdf([ shohi_p1, shohi_p2, shohi_p3 ], orientation: "full")
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
    f << { x: 40.35, y: 7.9, text: wareki.to_s, size: 13 }
    f << { x: 40.5, y: 12.5, text: @setting&.address.to_s, size: 9.5 }
    f << { x: 63.5, y: 13.3, text: @user.display_name.to_s, size: 12.5 }
    f << { x: 40.5, y: 23.2, text: "ソフトウェア・情報サービス業", size: 9 }
    f << { x: 66.3, y: 18.6, text: @setting&.tel.to_s, size: 9 }
    # 自1月1日 至12月31日
    f << { x: 57.6, y: 31.0, text: "1", size: 13 }
    f << { x: 62.2, y: 31.0, text: "1", size: 13 }
    f << { x: 66.6, y: 31.0, text: "12", size: 13 }
    f << { x: 71.2, y: 31.0, text: "31", size: 13 }

    # 左列 金額 (右端 x=20.5〜35.3 の右寄せ)
    lx, lw = 20.5, 14.6
    f << { x: lx, y: 39.7, w: lw, align: :right, text: fmt(@summary[:income_total]), size: 12.5 }
    f << { x: lx, y: 59.3, w: lw, align: :right, text: fmt(@summary[:income_total]), size: 12.5 }  # ⑦
    { 8 => 64.7, 9 => 67.65, 10 => 70.6, 11 => 73.55, 12 => 76.5, 13 => 79.45, 14 => 82.4, 15 => 85.35, 16 => 88.3 }.each do |no, y|
      cat = FIXED_CATEGORIES.key(no)
      f << { x: lx, y: y, w: lw, align: :right, text: fmt(totals[cat]), size: 13 }
    end

    # 中列 金額 (x=48.0〜63.7 右寄せ)
    mx, mw = 47.5, 15.0
    { 17 => 38.9, 18 => 41.77, 19 => 44.64, 20 => 47.51, 21 => 50.38, 22 => 53.25, 23 => 56.12, 24 => 58.99 }.each do |no, y|
      cat = FIXED_CATEGORIES.key(no)
      f << { x: mx, y: y, w: mw, align: :right, text: fmt(totals[cat]), size: 13 }
    end
    # 空欄枠 ㉕〜㉚ (科目名 + 金額)
    slot_ys = [ 62.0, 64.87, 67.74, 70.61, 73.48, 76.35 ]
    extra_categories.first(6).each_with_index do |row, i|
      f << { x: 38.5, y: slot_ys[i], text: row[:category], size: 9 }
      f << { x: mx, y: slot_ys[i], w: mw, align: :right, text: fmt(row[:total]), size: 13 }
    end
    f << { x: mx, y: 79.3, w: mw, align: :right, text: fmt(category_totals["雑費"]), size: 12 }             # ㉛
    f << { x: mx, y: 82.3, w: mw, align: :right, text: fmt0(@summary[:expense_total]), size: 12 }          # ㉜ 計
    f << { x: mx, y: 86.4, w: mw, align: :right, text: fmt0(profit_before_deduction), size: 12.5 }           # ㉝

    # 右列 ㊸㊹㊺ (x=76.7〜92.0 右寄せ)
    rx, rw = 76.7, 15.0
    f << { x: rx, y: 63.9, w: rw, align: :right, text: fmt0(profit_before_deduction), size: 12.5 }
    f << { x: rx, y: 67.9, w: rw, align: :right, text: fmt0(deduction_applied), size: 12.5 }
    f << { x: rx, y: 71.9, w: rw, align: :right, text: fmt0(final_income), size: 13 }

    { image_base64: form_base64("kessansho_p1.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # ============ 決算書 P2: 月別売上 + 青色申告特別控除の計算 ============
  def kessansho_p2
    f = []
    f << { x: 13.3, y: 5.8, text: wareki.to_s, size: 13 }
    f << { x: 21.0, y: 9.2, text: @user.display_name.to_s, size: 13 }
    # 月別売上 (1〜12月): 金額右寄せ x=13.0〜28.5
    sx, sw = 13.0, 15.0
    row0, row_h = 19.05, 3.05
    @summary[:monthly].each_with_index do |m, i|
      f << { x: sx, y: row0 + row_h * i, w: sw, align: :right, text: fmt(m[:income]), size: 13 }
    end
    f << { x: sx, y: 62.0, w: sw, align: :right, text: fmt0(@summary[:income_total]), size: 12.5 } # 計
    # 青色申告特別控除の計算 (右下): ⑦控除前所得 / ⑨控除額
    f << { x: 77.5, y: 80.4, w: 13.0, align: :right, text: fmt0(profit_before_deduction), size: 13 }
    f << { x: 77.5, y: 85.2, w: 13.0, align: :right, text: fmt0(deduction_applied), size: 13 }
    { image_base64: form_base64("kessansho_p2.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # ============ 決算書 P3: 売上明細 + 減価償却費の計算 ============
  def kessansho_p3
    f = []
    # 売上(収入)金額の明細: 上記以外の計 / 計
    f << { x: 57.0, y: 21.3, w: 11.5, align: :right, text: fmt0(@summary[:income_total]), size: 13 }
    f << { x: 57.0, y: 24.6, w: 11.5, align: :right, text: fmt0(@summary[:income_total]), size: 13 }
    # 減価償却費の計算 (資産ごと)
    row0, row_h = 57.7, 4.0
    @assets.first(7).each_with_index do |a, i|
      y = row0 + row_h * i
      annual = (a.cost / a.useful_life_years.to_f).floor
      months = a.acquired_on.year == @year ? (13 - a.acquired_on.month) : 12
      raw = @year < a.acquired_on.year ? 0 : (annual * months / 12.0).floor
      dep = a.depreciation_for(@year)
      f << { x: 3.2, y: y, text: a.name.to_s.slice(0, 10), size: 9.5 }
      f << { x: 10.2, y: y, text: "#{a.acquired_on.year % 100}・#{a.acquired_on.month}", size: 9.5 }
      f << { x: 14.5, y: y, w: 8.0, align: :right, text: fmt0(a.cost), size: 9.5 }
      f << { x: 24.0, y: y, w: 8.5, align: :right, text: fmt0(a.cost), size: 9.5 }
      f << { x: 33.0, y: y, text: "定額", size: 9.5 }
      f << { x: 37.8, y: y, text: a.useful_life_years.to_s, size: 9.5 }
      f << { x: 40.0, y: y, text: format("%.3f", 1.0 / a.useful_life_years), size: 9.5 }
      f << { x: 44.3, y: y, text: "#{months}/12", size: 9.5 }
      f << { x: 47.5, y: y, w: 7.5, align: :right, text: fmt0(raw), size: 9.5 }
      f << { x: 59.5, y: y, w: 6.5, align: :right, text: fmt0(raw), size: 9.5 }
      f << { x: 67.8, y: y, text: a.business_ratio.to_s, size: 9.5 }
      f << { x: 71.5, y: y, w: 7.5, align: :right, text: fmt0(dep), size: 9.5 }
    end
    if @assets.any?
      f << { x: 47.5, y: 84.5, w: 7.5, align: :right, text: fmt0(@summary[:depreciation_total]), size: 9.5 }
      f << { x: 71.5, y: 84.5, w: 7.5, align: :right, text: fmt0(@summary[:depreciation_total]), size: 9.5 }
    end
    { image_base64: form_base64("kessansho_p3.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # ============ 確定申告書 第一表 ============
  # 様式: 令和七年分用(FA2205・実物)。行: (31)課税所得 (32)税額 (42)差引 (44)再差引
  # (45)復興特別所得税 (46)合計 (50)申告納税額 (52)第3期分納める税金 (59)青色申告特別控除額
  def shinkokusho_page
    f = []
    f << { x: 14.5, y: 10.0, text: @setting&.address.to_s, size: 9.5 }
    f << { x: 60.0, y: 11.8, text: @user.display_name.to_s, size: 12.5 }
    f << { x: 49.0, y: 15.1, text: "ソフトウェア・情報サービス業", size: 7 }

    basic_deduction = 680_000 # 基礎控除
    taxable = [ ((final_income - basic_deduction) / 1000) * 1000, 0 ].max
    tax = income_tax_for(taxable)
    reconstruction = (tax * 0.021).floor
    total_tax = tax + reconstruction
    payment = (total_tax / 100) * 100

    money = ->(y, v) { { x: 30.0, y: y, w: 19.6, align: :right, text: fmt0(v), size: 12 } }
    f << money.call(20.4, @summary[:income_total])     # 収入 事業営業等(ア)
    f << money.call(42.2, final_income)                # 所得 事業①
    f << money.call(64.3, final_income)                # ⑫合計
    # ㉕基礎控除は下4桁0000がプレ印字 → 万円単位のみ刻印
    f << { x: 30.0, y: 84.8, w: 13.4, align: :right, text: fmt0(basic_deduction / 10_000), size: 13 }
    f << money.call(87.1, basic_deduction)             # ㉖13から25までの計

    rmoney = ->(y, v) { { x: 62.5, y: y, w: 22.3, align: :right, text: fmt0(v), size: 12 } }
    # (31)課税所得は下3桁000がプレ印字 → 千円単位のみ刻印
    f << { x: 62.5, y: 20.4, w: 16.0, align: :right, text: fmt0(taxable / 1000), size: 13 }
    f << rmoney.call(22.5, tax)                        # (32)税額
    f << rmoney.call(34.4, tax)                        # (42)差引所得税額
    f << rmoney.call(38.7, tax)                        # (44)再差引所得税額(基準所得税額)
    f << rmoney.call(40.3, reconstruction)             # (45)復興特別所得税額
    f << rmoney.call(42.3, total_tax)                  # (46)所得税及び復興特別所得税の額
    f << rmoney.call(48.5, payment)                    # (50)申告納税額
    # (52)納める税金は下2桁00がプレ印字 → 百円単位のみ刻印
    f << { x: 62.5, y: 52.3, w: 18.3, align: :right, text: fmt0(payment / 100), size: 13 }
    f << rmoney.call(66.5, deduction_applied)          # (59)青色申告特別控除額
    { image_base64: form_base64("shinkokusho_p1.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  # ============ 消費税申告書(2割特例) ============
  def ct = @summary[:consumption_tax][:breakdown]

  def shohi_p1
    f = []
    f << { x: 13.7, y: 25.4, text: wareki.to_s, size: 13 }  # 自 令和[8]年 (月日は様式に1月1日が印字済み)
    f << { x: 13.7, y: 29.9, text: wareki.to_s, size: 13 }  # 至 令和[8]年 (12月31日 印字済み)
    m = ->(y, v) { { x: 23.0, y: y, w: 32.2, align: :right, text: fmt0(v), size: 12 } }
    f << m.call(36.4, ct[:taxable_base])        # ①課税標準額
    f << m.call(38.5, ct[:national_tax])        # ②消費税額
    f << m.call(43.4, ct[:special_deduction])   # ④控除対象仕入税額(特別控除)
    f << m.call(49.5, ct[:special_deduction])   # ⑦控除税額小計
    f << m.call(54.0, ct[:national_payment])    # ⑨差引税額
    f << m.call(58.4, ct[:national_payment])    # ⑪納付税額
    f << m.call(75.7, ct[:national_payment])    # ⑱差引税額(地方の課税標準)
    f << m.call(80.2, ct[:local_payment])       # ⑳納税額(譲渡割額)
    f << m.call(84.6, ct[:local_payment])       # ㉒納付譲渡割額
    f << m.call(94.0, ct[:total_payment])       # ㉖合計(納付税額)
    { image_base64: form_base64("shohi_p1.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  def shohi_p2
    f = []
    f << { x: 14.2, y: 25.3, text: wareki.to_s, size: 13 }  # 自 令和[8]年
    f << { x: 14.2, y: 29.7, text: wareki.to_s, size: 13 }  # 至 令和[8]年
    m = ->(y, v) { { x: 57.5, y: y, w: 34.0, align: :right, text: fmt0(v), size: 12 } }
    f << m.call(33.9, ct[:taxable_base])        # ①課税標準額
    f << m.call(47.1, ct[:taxable_base_raw])    # ⑥7.8%適用分(対価の額)
    f << m.call(49.7, ct[:taxable_base_raw])    # ⑦計
    f << m.call(61.9, ct[:national_tax])        # ⑪消費税額
    f << m.call(72.8, ct[:national_tax])        # ⑯7.8%適用分
    f << m.call(86.7, ct[:national_payment])    # ⑳地方消費税の課税標準となる消費税額(計)
    f << m.call(93.1, ct[:national_payment])    # ㉓6.24%及び7.8%適用分
    { image_base64: form_base64("shohi_p2.png"), fields: f.reject { |x| x[:text].blank? } }
  end

  def shohi_p3
    f = []
    f << { x: 33.8, y: 13.0, text: "令#{wareki}・ 1・ 1 〜 令#{wareki}・12・31", size: 11 }
    b = ->(y, v) { { x: 48.0, y: y, w: 24.0, align: :right, text: fmt0(v), size: 11 } }
    c = ->(y, v) { { x: 73.5, y: y, w: 21.5, align: :right, text: fmt0(v), size: 11 } }
    f << b.call(27.6, ct[:taxable_base_raw]);  f << c.call(27.6, ct[:taxable_base_raw])   # ①対価の額
    f << b.call(33.1, ct[:taxable_base]);      f << c.call(33.1, ct[:taxable_base])       # ②課税標準額
    f << b.call(39.6, ct[:national_tax]);      f << c.call(39.6, ct[:national_tax])       # ③消費税額
    f << b.call(54.1, ct[:national_tax]);      f << c.call(54.1, ct[:national_tax])       # ⑥基礎となる消費税額
    f << b.call(67.1, ct[:special_deduction]); f << c.call(67.1, ct[:special_deduction])  # ⑦特別控除税額(80%)
    { image_base64: form_base64("shohi_p3.png"), fields: f.reject { |x| x[:text].blank? } }
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
