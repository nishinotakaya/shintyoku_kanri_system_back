require "thinreports"

# 国税庁の白紙様式(実物)に値を差し込んで「提出書類と同じ見た目」のPDFを作る。
# レイアウトは Thinreports (.tlf) — 座標マスタは TaxFormTlfLayouts、
# .tlf の再生成は `bin/rails runner script/build_tax_form_tlfs.rb`。
#
# kind:
#   :kessansho   青色申告決算書(一般用) P1損益計算書 / P2月別売上・特別控除 / P3減価償却・売上明細 (A4横)
#   :shinkokusho 確定申告書 第一表 (A4縦)
#   :shohi       消費税及び地方消費税申告書(2割特例) 第一表/第二表/付表6 (A4縦)
#                ※特別控除率は TaxSummaryBuilder が年度で切替（〜2026=2割特例80% / 2027・2028=3割特例70%）。
#                  2027年分からは付表6の様式改訂(⑥×80%→70%)が見込まれるため、公表され次第差し替えること
class OfficialTaxFormRenderer
  TLF_DIR = Rails.root.join("app/reports/tax_forms/tlf")

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
    render_pdf(kessansho_p1: kessansho_p1_values,
               kessansho_p2: kessansho_p2_values,
               kessansho_p3: kessansho_p3_values)
  end

  def render_shinkokusho
    render_pdf(shinkokusho_p1: shinkokusho_values)
  end

  def render_shohi
    render_pdf(shohi_p1: shohi_p1_values, shohi_p2: shohi_p2_values, shohi_p3: shohi_p3_values)
  end

  # === 集計値 ===
  def profit_before_deduction = @summary[:profit]
  def deduction_applied = [ [ profit_before_deduction, 0 ].max, @deduction ].min
  def final_income = profit_before_deduction - deduction_applied

  private

  # 各ページの {tlfキー => {項目id => 値}} を Thinreports で1つのPDFにまとめる
  def render_pdf(pages)
    report = Thinreports::Report.new
    pages.each do |layout_key, values|
      report.start_new_page(layout: TLF_DIR.join("#{layout_key}.tlf").to_s) do |page|
        values.each do |id, value|
          page.item(id).value(value.to_s) if page.item_exists?(id)
        end
      end
    end
    out_dir = Rails.root.join("tmp/exports")
    FileUtils.mkdir_p(out_dir)
    pdf_path = out_dir.join("taxform_#{@user.id}_#{SecureRandom.hex(4)}.pdf").to_s
    report.generate(filename: pdf_path)
    pdf_path
  end

  def fmt(n) = n.to_i.zero? ? "" : n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  def fmt0(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  def wareki = @year - 2018

  # コーム欄(1マス1桁)への桁割り。右端の記入可能マス(_d0)から下位桁を詰め、
  # マス数を超えた上位桁は幅広マス(_ov)にまとめて書く。
  def comb(page_key, id, number)
    spec = TaxFormTlfLayouts.comb(page_key, id)
    digits = number.to_i.to_s.chars.reverse
    fillable = spec[:cells] - spec.fetch(:skip, 0)
    values = digits.first(fillable).each_with_index.to_h { |digit, i| [ :"#{id}_d#{i}", digit ] }
    values[:"#{id}_ov"] = digits.drop(fillable).reverse.join if digits.size > fillable
    values
  end

  def category_totals
    @summary[:by_category].to_h { |row| [ row[:category], row[:total] ] }
  end

  # 決算書に固定枠が無いアプリ科目(会議費/新聞図書費/支払手数料/車両費/未分類) → 空欄枠㉕〜㉚
  def extra_categories
    @summary[:by_category].reject { |row| FIXED_CATEGORIES.key?(row[:category]) || row[:category] == "雑費" }
  end

  # ============ 決算書 P1: 損益計算書 ============
  def kessansho_p1_values
    totals = category_totals
    values = {
      wareki: wareki, address: @setting&.address, name: @user.display_name,
      job: "ソフトウェア・情報サービス業", tel: @setting&.tel,
      from_month: 1, from_day: 1, to_month: 12, to_day: 31,
      sales: fmt(@summary[:income_total]), sales_diff: fmt(@summary[:income_total]),
      misc_expense: fmt(totals["雑費"]),
      expense_total: fmt0(@summary[:expense_total]),
      profit_33: fmt0(profit_before_deduction),
      profit_43: fmt0(profit_before_deduction),
      deduction_44: fmt0(deduction_applied),
      income_45: fmt0(final_income)
    }
    FIXED_CATEGORIES.each_value do |no|
      values[:"cat_#{no}"] = fmt(totals[FIXED_CATEGORIES.key(no)])
    end
    extra_categories.first(6).each_with_index do |row, i|
      values[:"slot_#{i + 1}_label"] = row[:category]
      values[:"slot_#{i + 1}_amount"] = fmt(row[:total])
    end
    values
  end

  # ============ 決算書 P2: 月別売上 + 青色申告特別控除の計算 ============
  def kessansho_p2_values
    values = {
      wareki: wareki, name: @user.display_name,
      monthly_total: fmt0(@summary[:income_total]),
      profit_8: fmt0(profit_before_deduction),
      deduction_9: fmt0(deduction_applied)
    }
    @summary[:monthly].each_with_index do |m, i|
      values[:"month_#{i + 1}"] = fmt(m[:income])
    end
    values
  end

  # ============ 決算書 P3: 売上明細 + 減価償却費の計算 ============
  def kessansho_p3_values
    values = {
      sales_other: fmt0(@summary[:income_total]),
      sales_total: fmt0(@summary[:income_total])
    }
    @assets.first(7).each_with_index do |asset, i|
      n = i + 1
      annual = (asset.cost / asset.useful_life_years.to_f).floor
      months = asset.acquired_on.year == @year ? (13 - asset.acquired_on.month) : 12
      raw = @year < asset.acquired_on.year ? 0 : (annual * months / 12.0).floor
      values[:"asset_#{n}_name"]     = asset.name.to_s.slice(0, 10)
      values[:"asset_#{n}_acquired"] = "#{asset.acquired_on.year % 100}・#{asset.acquired_on.month}"
      values[:"asset_#{n}_cost"]     = fmt0(asset.cost)
      values[:"asset_#{n}_base"]     = fmt0(asset.cost)
      values[:"asset_#{n}_method"]   = "定額"
      values[:"asset_#{n}_life"]     = asset.useful_life_years
      values[:"asset_#{n}_rate"]     = format("%.3f", 1.0 / asset.useful_life_years)
      values[:"asset_#{n}_months"]   = "#{months}/12"
      values[:"asset_#{n}_dep"]      = fmt0(raw)
      values[:"asset_#{n}_dep_sum"]  = fmt0(raw)
      values[:"asset_#{n}_ratio"]    = asset.business_ratio
      values[:"asset_#{n}_expense"]  = fmt0(asset.depreciation_for(@year))
    end
    if @assets.any?
      values[:dep_total] = fmt0(@summary[:depreciation_total])
      values[:dep_total_expense] = fmt0(@summary[:depreciation_total])
    end
    values
  end

  # ============ 確定申告書 第一表 (令和7年分 FA2205) ============
  # ㉕基礎控除は下4桁0000・㉛課税所得は下3桁000・(52)納める税金は下2桁00がプレ印字
  def shinkokusho_values
    basic_deduction = 680_000
    taxable = [ ((final_income - basic_deduction) / 1000) * 1000, 0 ].max
    tax = income_tax_for(taxable)
    reconstruction = (tax * 0.021).floor
    total_tax = tax + reconstruction
    payment = (total_tax / 100) * 100

    { address: @setting&.address, name: @user.display_name, job: "ソフトウェア・情報サービス業" }.merge(
      comb(:shinkokusho_p1, :income_total, @summary[:income_total]),
      comb(:shinkokusho_p1, :business_income, final_income),
      comb(:shinkokusho_p1, :total_income, final_income),
      comb(:shinkokusho_p1, :basic_deduction_man, basic_deduction / 10_000),
      comb(:shinkokusho_p1, :deduction_sum, basic_deduction),
      comb(:shinkokusho_p1, :taxable_thousand, taxable / 1000),
      comb(:shinkokusho_p1, :tax_32, tax),
      comb(:shinkokusho_p1, :tax_42, tax),
      comb(:shinkokusho_p1, :tax_44, tax),
      comb(:shinkokusho_p1, :reconstruction_45, reconstruction),
      comb(:shinkokusho_p1, :total_tax_46, total_tax),
      comb(:shinkokusho_p1, :declared_tax_50, payment),
      comb(:shinkokusho_p1, :third_period_hundred, payment / 100),
      comb(:shinkokusho_p1, :blue_deduction_59, deduction_applied)
    )
  end

  # ============ 消費税申告書(2割特例) ============
  def ct = @summary[:consumption_tax][:breakdown]

  def shohi_p1_values
    { year_from: wareki, year_to: wareki }.merge(
      comb(:shohi_p1, :taxable_base, ct[:taxable_base]),
      comb(:shohi_p1, :national_tax, ct[:national_tax]),
      comb(:shohi_p1, :deduction, ct[:special_deduction]),
      comb(:shohi_p1, :deduction_sum, ct[:special_deduction]),
      comb(:shohi_p1, :national_payment_9, ct[:national_payment]),
      comb(:shohi_p1, :national_payment_11, ct[:national_payment]),
      comb(:shohi_p1, :local_base_18, ct[:national_payment]),
      comb(:shohi_p1, :local_payment_20, ct[:local_payment]),
      comb(:shohi_p1, :local_payment_22, ct[:local_payment]),
      comb(:shohi_p1, :total_payment_26, ct[:total_payment])
    )
  end

  def shohi_p2_values
    { year_from: wareki, year_to: wareki }.merge(
      comb(:shohi_p2, :taxable_base_1, ct[:taxable_base]),
      comb(:shohi_p2, :taxable_raw_6, ct[:taxable_base_raw]),
      comb(:shohi_p2, :taxable_raw_7, ct[:taxable_base_raw]),
      comb(:shohi_p2, :national_tax_11, ct[:national_tax]),
      comb(:shohi_p2, :national_tax_16, ct[:national_tax]),
      comb(:shohi_p2, :local_base_20, ct[:national_payment]),
      comb(:shohi_p2, :local_base_23, ct[:national_payment])
    )
  end

  def shohi_p3_values
    values = { period: "令#{wareki}・ 1・ 1 〜 令#{wareki}・12・31" }
    { raw_1: ct[:taxable_base_raw], base_2: ct[:taxable_base], tax_3: ct[:national_tax],
      basis_6: ct[:national_tax], special_deduction_7: ct[:special_deduction] }.each do |id, v|
      values[:"#{id}_b"] = fmt0(v)
      values[:"#{id}_c"] = fmt0(v)
    end
    values
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
