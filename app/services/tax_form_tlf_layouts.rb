# 確定申告/消費税の実物様式 .tlf レイアウト定義（単一の座標マスタ）。
#
# - x/y/w は用紙に対する % （左上原点）。y はテキスト上端。size は従来の overlay px 指定
#   （.tlf 生成時に pt へ換算する）。align 省略時は左寄せ。ja: true は日本語フォント(IPAMincho)。
# - この定義から script/build_tax_form_tlfs.rb が app/reports/tax_forms/tlf/*.tlf を生成し、
#   OfficialTaxFormRenderer が id => 値 を流し込む。
#   位置を調整したい場合は .tlf を Thinreports Editor で直接編集してもよい
#   （その場合ここの数値と乖離するので、再生成すると Editor の調整は失われる点に注意）。
module TaxFormTlfLayouts
  # 決算書P1 経費欄の科目番号→行 y%
  KESSANSHO_LEFT_ROWS = {
    8 => 64.3, 9 => 67.2, 10 => 70.2, 11 => 73.1, 12 => 76.0,
    13 => 79.0, 14 => 81.9, 15 => 84.8, 16 => 87.7
  }.freeze
  KESSANSHO_MID_ROWS = {
    17 => 37.9, 18 => 40.85, 19 => 43.75, 20 => 46.7,
    21 => 49.65, 22 => 52.55, 23 => 55.5, 24 => 58.4
  }.freeze
  KESSANSHO_SLOT_YS = [ 61.35, 64.3, 67.2, 70.15, 73.1, 76.0 ].freeze

  def self.pages
    @pages ||= build_pages.freeze
  end

  def self.build_pages
    pages = {}

    # ============ 青色申告決算書 P1: 損益計算書 (A4横) ============
    f = []
    f << { id: :wareki,  x: 40.35, y: 7.9,  w: 4.0,  size: 13 }
    f << { id: :address, x: 40.5,  y: 12.5, w: 26.0, size: 9.5, ja: true }
    f << { id: :name,    x: 63.5,  y: 13.3, w: 15.0, size: 12.5, ja: true }
    f << { id: :job,     x: 40.5,  y: 23.2, w: 20.0, size: 9,   ja: true }
    f << { id: :tel,     x: 66.3,  y: 18.6, w: 15.0, size: 9 }
    f << { id: :from_month, x: 57.6, y: 31.0, w: 3.0, size: 13 }
    f << { id: :from_day,   x: 62.2, y: 31.0, w: 3.0, size: 13 }
    f << { id: :to_month,   x: 66.6, y: 31.0, w: 3.5, size: 13 }
    f << { id: :to_day,     x: 71.2, y: 31.0, w: 3.5, size: 13 }
    f << { id: :sales,      x: 20.5, y: 39.4, w: 14.6, size: 13.5, align: :right }
    f << { id: :sales_diff, x: 20.5, y: 59.9, w: 14.6, size: 13.5, align: :right }
    KESSANSHO_LEFT_ROWS.each do |no, y|
      f << { id: :"cat_#{no}", x: 20.5, y: y, w: 14.6, size: 14, align: :right }
    end
    KESSANSHO_MID_ROWS.each do |no, y|
      f << { id: :"cat_#{no}", x: 47.5, y: y, w: 15.0, size: 14, align: :right }
    end
    KESSANSHO_SLOT_YS.each_with_index do |y, i|
      f << { id: :"slot_#{i + 1}_label",  x: 38.5, y: y, w: 9.0,  size: 9, ja: true }
      f << { id: :"slot_#{i + 1}_amount", x: 47.5, y: y, w: 15.0, size: 14, align: :right }
    end
    f << { id: :misc_expense,  x: 47.5, y: 78.95, w: 15.0, size: 14, align: :right } # ㉛雑費
    f << { id: :expense_total, x: 47.5, y: 81.9,  w: 15.0, size: 14, align: :right } # ㉜計
    f << { id: :profit_33,     x: 47.5, y: 86.3,  w: 15.0, size: 14, align: :right } # ㉝差引金額
    f << { id: :profit_43,     x: 76.7, y: 64.3,  w: 15.0, size: 14, align: :right } # ㊸控除前所得
    f << { id: :deduction_44,  x: 76.7, y: 67.3,  w: 15.0, size: 14, align: :right } # ㊹特別控除額
    f << { id: :income_45,     x: 76.7, y: 71.6,  w: 15.0, size: 14, align: :right } # ㊺所得金額
    pages[:kessansho_p1] = { image: "kessansho_p1.png", orientation: "landscape", fields: f }

    # ============ 決算書 P2: 月別売上 + 特別控除の計算 (A4横) ============
    f = []
    f << { id: :wareki, x: 13.3, y: 5.8, w: 4.0,  size: 13 }
    f << { id: :name,   x: 21.0, y: 9.2, w: 20.0, size: 13, ja: true }
    12.times do |i|
      f << { id: :"month_#{i + 1}", x: 13.0, y: 18.8 + 2.941 * i, w: 15.0, size: 14, align: :right }
    end
    f << { id: :monthly_total, x: 13.0, y: 61.4, w: 15.0, size: 14, align: :right }
    f << { id: :profit_8,      x: 77.5, y: 80.6, w: 13.0, size: 14, align: :right }
    f << { id: :deduction_9,   x: 77.5, y: 83.4, w: 13.0, size: 14, align: :right }
    pages[:kessansho_p2] = { image: "kessansho_p2.png", orientation: "landscape", fields: f }

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
    f << { id: :address, x: 14.5, y: 10.0, w: 42.0, size: 9.5,  ja: true }
    f << { id: :name,    x: 60.0, y: 11.8, w: 25.0, size: 12.5, ja: true }
    f << { id: :job,     x: 49.0, y: 15.1, w: 20.0, size: 7,    ja: true }
    f << { id: :income_total,       x: 30.0, y: 19.8, w: 19.6, size: 13.5, align: :right } # (ア)営業等収入
    f << { id: :business_income,    x: 30.0, y: 42.0, w: 19.6, size: 13.5, align: :right } # ①事業所得
    f << { id: :total_income,       x: 30.0, y: 64.0, w: 19.6, size: 13.5, align: :right } # ⑫合計
    f << { id: :basic_deduction_man, x: 30.0, y: 84.4, w: 10.4, size: 14, align: :right }  # ㉕基礎控除(万円・0000前)
    f << { id: :deduction_sum,      x: 30.0, y: 86.3, w: 19.6, size: 13.5, align: :right } # ㉖⑬〜㉕計
    f << { id: :taxable_thousand,   x: 62.5, y: 19.6, w: 22.7, size: 14, align: :right }   # ㉛課税所得(千円・000前)
    f << { id: :tax_32,             x: 62.5, y: 21.7, w: 30.5, size: 13.5, align: :right } # ㉜税額
    f << { id: :tax_42,             x: 62.5, y: 33.7, w: 30.5, size: 13.5, align: :right } # ㊷差引所得税額
    f << { id: :tax_44,             x: 62.5, y: 37.7, w: 30.5, size: 13.5, align: :right } # ㊹基準所得税額
    f << { id: :reconstruction_45,  x: 62.5, y: 39.9, w: 30.5, size: 13.5, align: :right } # ㊺復興特別所得税
    f << { id: :total_tax_46,       x: 62.5, y: 41.8, w: 30.5, size: 13.5, align: :right } # ㊻合計
    f << { id: :declared_tax_50,    x: 62.5, y: 47.8, w: 30.5, size: 13.5, align: :right } # (50)申告納税額
    f << { id: :third_period_hundred, x: 62.5, y: 51.9, w: 25.0, size: 14, align: :right } # (52)納める税金(百円・00前)
    f << { id: :blue_deduction_59,  x: 62.5, y: 66.3, w: 30.5, size: 13.5, align: :right } # (59)青色申告特別控除額
    pages[:shinkokusho_p1] = { image: "shinkokusho_p1.png", orientation: "portrait", fields: f }

    # ============ 消費税申告書 第一表 GK0306 (A4縦) ============
    f = []
    f << { id: :year_from, x: 13.7, y: 25.4, w: 3.0, size: 13 }
    f << { id: :year_to,   x: 13.7, y: 29.9, w: 3.0, size: 13 }
    {
      taxable_base: 36.4, national_tax: 38.5, deduction: 43.4, deduction_sum: 49.5,
      national_payment_9: 54.0, national_payment_11: 58.4, local_base_18: 75.7,
      local_payment_20: 80.2, local_payment_22: 84.6, total_payment_26: 94.0
    }.each do |id, y|
      f << { id: id, x: 23.0, y: y, w: 32.2, size: 12, align: :right }
    end
    pages[:shohi_p1] = { image: "shohi_p1.png", orientation: "portrait", fields: f }

    # ============ 消費税申告書 第二表 GK0602 (A4縦) ============
    f = []
    f << { id: :year_from, x: 14.2, y: 25.3, w: 3.0, size: 13 }
    f << { id: :year_to,   x: 14.2, y: 29.7, w: 3.0, size: 13 }
    {
      taxable_base_1: 33.9, taxable_raw_6: 47.1, taxable_raw_7: 49.7,
      national_tax_11: 61.9, national_tax_16: 72.8,
      local_base_20: 86.7, local_base_23: 93.1
    }.each do |id, y|
      f << { id: id, x: 57.5, y: y, w: 34.0, size: 12, align: :right }
    end
    pages[:shohi_p2] = { image: "shohi_p2.png", orientation: "portrait", fields: f }

    # ============ 消費税 付表6 (A4縦) ============
    f = []
    f << { id: :period, x: 33.8, y: 13.0, w: 25.0, size: 11, ja: true }
    { raw_1: 27.6, base_2: 33.1, tax_3: 39.6, basis_6: 54.1, special_deduction_7: 67.1 }.each do |id, y|
      f << { id: :"#{id}_b", x: 48.0, y: y, w: 24.0, size: 11, align: :right }
      f << { id: :"#{id}_c", x: 73.5, y: y, w: 21.5, size: 11, align: :right }
    end
    pages[:shohi_p3] = { image: "shohi_p3.png", orientation: "portrait", fields: f }

    pages
  end
end
