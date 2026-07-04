# 確定申告/消費税の実物様式 .tlf レイアウト定義（単一の座標マスタ）。
#
# - x/y/w は用紙に対する % （左上原点）。y はテキスト上端。size は従来の overlay px 指定
#   （.tlf 生成時に pt へ換算する）。align 省略時は左寄せ。ja: true は日本語フォント(IPAMincho)。
# - この定義から script/build_tax_form_tlfs.rb が app/reports/tax_forms/tlf/*.tlf を生成し、
#   OfficialTaxFormRenderer が id => 値 を流し込む。
#   位置を調整したい場合は .tlf を Thinreports Editor で直接編集してもよい
#   （その場合ここの数値と乖離するので、再生成すると Editor の調整は失われる点に注意）。
# - combs: OCR用の1マス1桁記入枠。y はマス中心、x_right は最右マスの中心、pitch はマス間隔
#   （いずれも%）。cells はマス数、skip は様式にプレ印字された「000」等で潰れている右端マス数。
#   overflow はマスに収まらない上位桁を書く幅広マス（第一表の左端）。
#   座標は背景PNGのプレ印字0・e-Tax印字数字のピクセル走査から採寸した。
module TaxFormTlfLayouts
  # 決算書P1(FA3001) 損益計算書のコーム行 y%（e-Tax提出済みPDFの印字位置から採寸）
  KESSANSHO_LEFT_ROWS = {
    sales: 40.36, sales_diff: 60.85,
    cat_8: 65.20, cat_9: 68.15, cat_10: 71.09, cat_11: 73.99, cat_12: 77.06,
    cat_13: 79.96, cat_14: 82.86, cat_15: 85.81, cat_16: 88.75
  }.freeze
  KESSANSHO_MID_ROWS = {
    cat_17: 38.99, cat_18: 41.90, cat_19: 44.80, cat_20: 47.70, cat_21: 50.65,
    cat_22: 53.55, cat_23: 56.49, cat_24: 59.40,
    slot_1_amount: 62.46, slot_2_amount: 65.36, slot_3_amount: 68.28,
    slot_4_amount: 71.20, slot_5_amount: 74.12, slot_6_amount: 77.04,
    misc_expense: 79.96, expense_total: 82.86, profit_33: 87.30
  }.freeze
  KESSANSHO_RIGHT_ROWS = { profit_43: 65.36, deduction_44: 68.19, income_45: 72.70 }.freeze
  # P2(FA3026) 月別売上の行 y%（自由記入行・右寄せテキスト）
  KESSANSHO_MONTH_YS = [
    18.77, 21.68, 24.58, 27.56, 30.47, 33.37, 36.27, 39.34, 42.24, 45.06, 47.97, 51.03
  ].freeze

  def self.pages
    @pages ||= build_pages.freeze
  end

  def self.comb(page_key, id)
    pages.fetch(page_key)[:combs].find { |comb_field| comb_field[:id] == id } ||
      raise(ArgumentError, "comb not found: #{page_key}/#{id}")
  end

  # コーム欄(1マス1桁)への桁割り。右端の記入可能マス(_d0)から下位桁を詰め、
  # マス数を超えた上位桁は幅広マス(_ov)にまとめて書く。
  # number に String を渡すとゼロ埋め等をそのまま桁割りする（例: 年号 "08"）。
  def self.comb_digits(page_key, id, number)
    spec = comb(page_key, id)
    digits = (number.is_a?(String) ? number : number.to_i.to_s).chars.reverse
    fillable = spec[:cells] - spec.fetch(:skip, 0)
    values = digits.first(fillable).each_with_index.to_h { |digit, i| [ :"#{id}_d#{i}", digit ] }
    values[:"#{id}_ov"] = digits.drop(fillable).reverse.join if digits.size > fillable
    values
  end

  def self.build_pages
    pages = {}

    # ============ 青色申告決算書 P1: 損益計算書 (A4横・FA3001) ============
    # 金額欄は「幅広マス+7マス」のコーム。座標は e-Tax 提出済みPDFの印字位置から採寸
    f = []
    f << { id: :address, x: 38.92, y: 12.89, w: 18.5, size: 11, ja: true, lines: 2 }
    f << { id: :doujou,  x: 38.92, y: 18.37, w: 8.0,  size: 11, ja: true }  # 事業所所在地「同上」
    f << { id: :name,    x: 62.05, y: 14.69, w: 14.5, size: 14, ja: true }
    f << { id: :job,     x: 38.80, y: 22.90, w: 9.4, size: 7, ja: true }
    f << { id: :tel,     x: 66.10, y: 17.12, w: 9.0, size: 11 }
    # 損益計算書の期間 (自[1]月[1]日 至[12]月[31]日) — 各ボックス中央寄せ
    f << { id: :from_month, x: 53.23, y: 30.99, w: 3.0, size: 19, align: :center }
    f << { id: :from_day,   x: 58.19, y: 30.99, w: 3.0, size: 19, align: :center }
    f << { id: :to_month,   x: 64.17, y: 30.99, w: 3.0, size: 19, align: :center }
    f << { id: :to_day,     x: 69.13, y: 30.99, w: 3.0, size: 19, align: :center }
    left_grid  = { x_right: 35.04, pitch: 1.635, cells: 7, size: 16.2, overflow: { x: 22.74, w: 3.13 } }
    mid_grid   = { x_right: 63.22, pitch: 1.630, cells: 7, size: 16.2, overflow: { x: 50.71, w: 2.85 } }
    right_grid = { x_right: 91.40, pitch: 1.624, cells: 7, size: 16.2, overflow: { x: 79.09, w: 3.13 } }
    combs = [ { id: :wareki, x_right: 41.82, pitch: 1.652, cells: 2, size: 22, y: 9.56 } ] # 令和[0][8]
    KESSANSHO_LEFT_ROWS.each { |id, y| combs << left_grid.merge(id: id, y: y) }
    KESSANSHO_MID_ROWS.each  { |id, y| combs << mid_grid.merge(id: id, y: y) }
    KESSANSHO_RIGHT_ROWS.each { |id, y| combs << right_grid.merge(id: id, y: y) }
    6.times do |i|
      f << { id: :"slot_#{i + 1}_label", x: 38.5, y: KESSANSHO_MID_ROWS[:"slot_#{i + 1}_amount"] - 0.64, w: 9.0, size: 9, ja: true }
    end
    pages[:kessansho_p1] = { image: "kessansho_p1.png", orientation: "landscape", fields: f, combs: combs }

    # ============ 決算書 P2: 月別売上 + 特別控除の計算 (A4横・FA3026) ============
    f = []
    f << { id: :name, x: 23.30, y: 9.17, w: 20.0, size: 13, ja: true }
    KESSANSHO_MONTH_YS.each_with_index do |y, i|
      f << { id: :"month_#{i + 1}", x: 10.56, y: y, w: 15.0, size: 15, align: :right }
    end
    f << { id: :profit_8,    x: 77.5, y: 80.6, w: 13.0, size: 14, align: :right }
    f << { id: :deduction_9, x: 77.5, y: 83.4, w: 13.0, size: 14, align: :right }
    combs = [
      { id: :wareki, x_right: 14.42, pitch: 1.595, cells: 2, size: 21, y: 6.64 },
      { id: :monthly_total, x_right: 25.16, pitch: 1.624, cells: 7, size: 16.2,
        y: 62.46, overflow: { x: 12.99, w: 2.85 } }
    ]
    pages[:kessansho_p2] = { image: "kessansho_p2.png", orientation: "landscape", fields: f, combs: combs }

    # ============ 決算書 P3: 売上明細 + 減価償却費の計算 (A4横) ============
    f = []
    f << { id: :sales_other, x: 57.0, y: 21.3, w: 11.5, size: 13, align: :right }
    f << { id: :sales_total, x: 57.0, y: 24.6, w: 11.5, size: 13, align: :right }
    7.times do |i|
      y = 57.7 + 4.0 * i
      n = i + 1
      f << { id: :"asset_#{n}_name",     x: 3.2,  y: y, w: 7.0, size: 9.5, ja: true }
      f << { id: :"asset_#{n}_acquired", x: 10.2, y: y, w: 4.2, size: 9.5, ja: true }
      f << { id: :"asset_#{n}_cost",     x: 14.5, y: y, w: 8.0, size: 9.5, align: :right }
      f << { id: :"asset_#{n}_base",     x: 24.0, y: y, w: 8.5, size: 9.5, align: :right }
      f << { id: :"asset_#{n}_method",   x: 33.0, y: y, w: 4.0, size: 9.5, ja: true }
      f << { id: :"asset_#{n}_life",     x: 37.8, y: y, w: 2.0, size: 9.5 }
      f << { id: :"asset_#{n}_rate",     x: 40.0, y: y, w: 3.5, size: 9.5 }
      f << { id: :"asset_#{n}_months",   x: 44.3, y: y, w: 3.3, size: 9.5 }
      f << { id: :"asset_#{n}_dep",      x: 47.5, y: y, w: 7.5, size: 9.5, align: :right }
      f << { id: :"asset_#{n}_dep_sum",  x: 59.5, y: y, w: 6.5, size: 9.5, align: :right }
      f << { id: :"asset_#{n}_ratio",    x: 67.8, y: y, w: 2.5, size: 9.5 }
      f << { id: :"asset_#{n}_expense",  x: 71.5, y: y, w: 7.5, size: 9.5, align: :right }
    end
    f << { id: :dep_total,         x: 47.5, y: 84.5, w: 7.5, size: 9.5, align: :right }
    f << { id: :dep_total_expense, x: 71.5, y: 84.5, w: 7.5, size: 9.5, align: :right }
    pages[:kessansho_p3] = { image: "kessansho_p3.png", orientation: "landscape", fields: f }

    # ============ 確定申告書 第一表 (A4縦・令和7年分 FA2205) ============
    f = []
    f << { id: :tax_office, x: 8.03, y: 3.33, w: 9.6, size: 11, ja: true, align: :right } # 「◯◯税務署長」の前
    f << { id: :address, x: 14.5, y: 10.0, w: 42.0, size: 9.5,  ja: true }
    f << { id: :name,    x: 60.0, y: 11.8, w: 25.0, size: 12.5, ja: true }
    f << { id: :job,     x: 49.0, y: 15.1, w: 20.0, size: 7,    ja: true }
    # 左列(収入・所得・控除)/右列(税金の計算)の桁マス。行ピッチ2.024%(=34.375px@150dpi)
    left_grid  = { x_right: 48.80, pitch: 2.401, cells: 7, size: 22, overflow: { x: 30.71, w: 4.30 } }
    right_grid = { x_right: 92.22, pitch: 2.421, cells: 7, size: 22, overflow: { x: 74.13, w: 4.39 } }
    combs = []
    combs << left_grid.merge(id: :income_total,        y: 20.26)          # (ア)営業等収入
    combs << left_grid.merge(id: :business_income,     y: 42.52)          # ①事業所得
    combs << left_grid.merge(id: :total_income,        y: 64.78)          # ⑫合計
    combs << left_grid.merge(id: :basic_deduction_man, y: 85.01, skip: 4) # ㉕基礎控除(万円・0000前)
    combs << left_grid.merge(id: :deduction_sum,       y: 87.04)          # ㉖⑬〜㉕計
    combs << right_grid.merge(id: :taxable_thousand,   y: 20.26, skip: 3) # ㉛課税所得(千円・000前)
    combs << right_grid.merge(id: :tax_32,             y: 22.28)          # ㉜税額
    combs << right_grid.merge(id: :tax_42,             y: 34.43)          # ㊷差引所得税額
    combs << right_grid.merge(id: :tax_44,             y: 38.48)          # ㊹基準所得税額
    combs << right_grid.merge(id: :reconstruction_45,  y: 40.51)          # ㊺復興特別所得税
    combs << right_grid.merge(id: :total_tax_46,       y: 42.53)          # ㊻合計
    combs << right_grid.merge(id: :declared_tax_50,    y: 48.60)          # (50)申告納税額
    combs << right_grid.merge(id: :third_period_hundred, y: 52.65, skip: 2) # (52)納める税金(百円・00前)
    combs << right_grid.merge(id: :blue_deduction_59,  y: 66.81)          # (59)青色申告特別控除額
    pages[:shinkokusho_p1] = { image: "shinkokusho_p1.png", orientation: "portrait", fields: f, combs: combs }

    # ============ 消費税申告書 第一表 GK0306 (A4縦) ============
    f = []
    f << { id: :tax_office, x: 30.00, y: 5.82,  w: 14.35, size: 13, ja: true, align: :right } # 「◯◯税務署長殿」の前
    f << { id: :address,    x: 15.73, y: 9.03,  w: 37.5,  size: 11, ja: true }
    f << { id: :tel_a, x: 31.26, y: 11.36, w: 4.5, size: 10.5, align: :center }
    f << { id: :tel_b, x: 38.11, y: 11.36, w: 4.5, size: 10.5, align: :center }
    f << { id: :tel_c, x: 45.69, y: 11.36, w: 4.5, size: 10.5, align: :center }
    f << { id: :name,  x: 14.68, y: 21.82, w: 30.0, size: 14, ja: true }
    f << { id: :year_from, x: 13.7, y: 25.4, w: 3.0, size: 13 }
    f << { id: :year_to,   x: 13.7, y: 29.9, w: 3.0, size: 13 }
    # 十兆〜一円の14マス。e-Tax印字と同じ大きさ(15.5)・位置
    grid = { x_right: 55.20, pitch: 2.468, cells: 14, size: 16.7 }
    combs = []
    {
      taxable_base: 36.92, national_tax: 39.00, deduction: 43.44, deduction_sum: 49.94,
      national_payment_9: 54.35, national_payment_11: 58.68, local_base_18: 76.08,
      local_payment_20: 80.43, local_payment_22: 84.77, total_payment_26: 94.58
    }.each do |id, y|
      combs << grid.merge(id: id, y: y)
    end
    pages[:shohi_p1] = { image: "shohi_p1.png", orientation: "portrait", fields: f, combs: combs }

    # ============ 消費税申告書 第二表 GK0602 (A4縦) ============
    f = []
    f << { id: :address, x: 14.76, y: 8.48, w: 37.7, size: 11, ja: true, lines: 2 }
    f << { id: :tel_a, x: 31.26, y: 11.79, w: 4.5, size: 10.5, align: :center }
    f << { id: :tel_b, x: 38.11, y: 11.79, w: 4.5, size: 10.5, align: :center }
    f << { id: :tel_c, x: 45.69, y: 11.79, w: 4.5, size: 10.5, align: :center }
    f << { id: :name,  x: 14.76, y: 18.85, w: 30.0, size: 14, ja: true }
    f << { id: :year_from, x: 14.2, y: 25.3, w: 3.0, size: 13 }
    f << { id: :year_to,   x: 14.2, y: 29.7, w: 3.0, size: 13 }
    grid = { x_right: 90.85, pitch: 2.468, cells: 14, size: 16.7 }
    combs = []
    {
      taxable_base_1: 35.82, taxable_raw_6: 48.86, taxable_raw_7: 50.97,
      national_tax_11: 62.43, national_tax_16: 73.32,
      local_base_20: 86.94, local_base_23: 93.44
    }.each do |id, y|
      combs << grid.merge(id: id, y: y)
    end
    pages[:shohi_p2] = { image: "shohi_p2.png", orientation: "portrait", fields: f, combs: combs }

    # ============ 消費税 付表6 (A4縦) ============
    f = []
    f << { id: :period, x: 33.8, y: 13.0, w: 25.0, size: 11, ja: true }
    f << { id: :name, x: 56.45, y: 12.98, w: 25.0, size: 14, ja: true }
    # 各セルとも e-Tax 印字の位置(セル下部・右寄せ)に合わせている
    { raw_1: 28.44, base_2: 33.40, tax_3: 39.56, basis_6: 56.61, special_deduction_7: 68.52 }.each do |id, y|
      f << { id: :"#{id}_b", x: 48.0, y: y, w: 24.0, size: 11, align: :right }
      f << { id: :"#{id}_c", x: 73.5, y: y, w: 19.2, size: 11, align: :right }
    end
    pages[:shohi_p3] = { image: "shohi_p3.png", orientation: "portrait", fields: f, combs: [] }

    pages
  end
end
