require_relative "../test_helper"

# 消費税の特例計算（2割特例/3割特例）と、免税事業者（インボイス未登録）からの
# 仕入税額控除の経過措置のテスト。DB に依存しない純粋な計算部分を検証する。
class TaxSummaryBuilderConsumptionTaxTest < Minitest::Test
  # 2026年分(令和8年分)までは2割特例（納付 = 売上税額の2割）
  def test_special_rate_is_20_percent_until_2026
    builder = TaxSummaryBuilder.new(nil, 2026)
    assert_in_delta 0.2, builder.send(:special_payment_rate)
    assert_equal "2割特例", builder.send(:special_label)
  end

  # 2027・2028年分(令和9・10年分)は個人限定の3割特例（2026年度税制改正で延長）
  def test_special_rate_is_30_percent_for_2027_and_2028
    [ 2027, 2028 ].each do |year|
      builder = TaxSummaryBuilder.new(nil, year)
      assert_in_delta 0.3, builder.send(:special_payment_rate)
      assert_equal "3割特例", builder.send(:special_label)
    end
  end

  # 付表6と同一方式の計算チェーン:
  # 税抜対価(切捨て) → 課税標準額(千円切捨て) → 国税7.8% → 特別控除 → 差引(百円切捨て) → 地方22/78(百円切捨て)
  def test_consumption_tax_breakdown_2026
    breakdown = breakdown_for(year: 2026, income_total: 7_700_000)
    assert_equal 7_000_000, breakdown[:taxable_base_raw]
    assert_equal 7_000_000, breakdown[:taxable_base]
    assert_equal 546_000, breakdown[:national_tax]          # 7.8%
    assert_equal 436_800, breakdown[:special_deduction]     # 80%控除
    assert_equal 109_200, breakdown[:national_payment]
    assert_equal 30_800, breakdown[:local_payment]          # ×22/78
    assert_equal 140_000, breakdown[:total_payment]
  end

  def test_consumption_tax_breakdown_2027_uses_30_percent
    breakdown = breakdown_for(year: 2027, income_total: 7_700_000)
    assert_equal 382_200, breakdown[:special_deduction]     # 70%控除
    assert_equal 163_800, breakdown[:national_payment]
    assert_equal 46_200, breakdown[:local_payment]
    assert_equal 210_000, breakdown[:total_payment]         # 2026年の1.5倍
  end

  def test_block_exposes_rate_and_label
    builder = stubbed_builder(2027)
    block = builder.send(:consumption_tax_block, 7_700_000, [])
    assert_equal 30, block[:special_rate_percent]
    assert_equal "3割特例", block[:special_label]
    assert_equal block[:special20_payment], block[:breakdown][:total_payment]
  end

  # 免税事業者からの仕入税額控除率: 2023/10-2026/9=80%, 2026/10-2029/9=50%, 2029/10以降=0%
  def test_exempt_supplier_deduction_rate_schedule
    builder = TaxSummaryBuilder.new(nil, 2026)
    assert_in_delta 0.8, builder.send(:exempt_supplier_deduction_rate, 2026, 9)
    assert_in_delta 0.5, builder.send(:exempt_supplier_deduction_rate, 2026, 10)
    assert_in_delta 0.5, builder.send(:exempt_supplier_deduction_rate, 2029, 9)
    assert_in_delta 0.0, builder.send(:exempt_supplier_deduction_rate, 2029, 10)
    assert_in_delta 0.8, builder.send(:exempt_supplier_deduction_rate, 2025, 1)
  end

  # 2026年は9月まで80%・10月以降50%の2区間に分かれる
  def test_exempt_supplier_deduction_bands_2026
    builder = TaxSummaryBuilder.new(nil, 2026)
    expected_bands = [
      { from_month: 1, to_month: 9, percent: 80 },
      { from_month: 10, to_month: 12, percent: 50 }
    ]
    assert_equal expected_bands, builder.send(:exempt_supplier_deduction_bands)
  end

  # 2027年は年間を通して50%の1区間
  def test_exempt_supplier_deduction_bands_2027
    builder = TaxSummaryBuilder.new(nil, 2027)
    expected_bands = [
      { from_month: 1, to_month: 12, percent: 50 }
    ]
    assert_equal expected_bands, builder.send(:exempt_supplier_deduction_bands)
  end

  # 2029年は9月まで50%・10月以降0%の2区間に分かれる
  def test_exempt_supplier_deduction_bands_2029
    builder = TaxSummaryBuilder.new(nil, 2029)
    expected_bands = [
      { from_month: 1, to_month: 9, percent: 50 },
      { from_month: 10, to_month: 12, percent: 0 }
    ]
    assert_equal expected_bands, builder.send(:exempt_supplier_deduction_bands)
  end

  # 免税事業者(インボイス未登録)への外注費は、請求月ごとの経過措置控除率が適用される
  def test_subcontract_tax_uses_monthly_rate_for_exempt_partner
    builder = TaxSummaryBuilder.new(nil, 2026)
    exempt_partner = Struct.new(:invoice_registered?).new(false)
    submission_struct = Struct.new(:user, :month, :total_override)
    september_submission = submission_struct.new(exempt_partner, 9, 110_000)
    october_submission = submission_struct.new(exempt_partner, 10, 110_000)
    builder.define_singleton_method(:subcontract_incomes) { [ september_submission, october_submission ] }

    block = builder.send(:consumption_tax_block, 0, [])

    # 各月の税額は 110,000 * 10 / 110 = 10,000
    # 9月分は控除率80% → 8,000 / 10月分は控除率50% → 5,000
    assert_equal 13_000, block[:purchase_tax]
  end

  # インボイス登録済みパートナーへの外注費は経過措置の対象外で全額控除される
  def test_subcontract_tax_full_deduction_for_registered_partner
    builder = TaxSummaryBuilder.new(nil, 2026)
    registered_partner = Struct.new(:invoice_registered?).new(true)
    submission_struct = Struct.new(:user, :month, :total_override)
    september_submission = submission_struct.new(registered_partner, 9, 110_000)
    october_submission = submission_struct.new(registered_partner, 10, 110_000)
    builder.define_singleton_method(:subcontract_incomes) { [ september_submission, october_submission ] }

    block = builder.send(:consumption_tax_block, 0, [])

    # 各月の税額 10,000 が全額控除されるので 9月 + 10月 = 20,000
    assert_equal 20_000, block[:purchase_tax]
  end

  # consumption_tax_block は画面表示用に経過措置スケジュールをそのまま公開する
  def test_block_exposes_exempt_supplier_deduction_bands
    builder = stubbed_builder(2026)
    block = builder.send(:consumption_tax_block, 7_700_000, [])
    expected_bands = [
      { from_month: 1, to_month: 9, percent: 80 },
      { from_month: 10, to_month: 12, percent: 50 }
    ]
    assert_equal expected_bands, block[:exempt_supplier_deduction_bands]
  end

  private

  def stubbed_builder(year)
    builder = TaxSummaryBuilder.new(nil, year)
    # 外注合算(subcontract_incomes)は DB を見るので空にスタブ
    def builder.subcontract_incomes = []
    builder
  end

  def breakdown_for(year:, income_total:)
    stubbed_builder(year).send(:consumption_tax_block, income_total, [])[:breakdown]
  end
end
