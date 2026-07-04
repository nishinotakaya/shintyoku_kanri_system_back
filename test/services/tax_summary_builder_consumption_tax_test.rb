require_relative "../test_helper"

# 消費税の特例計算（2割特例/3割特例）のテスト。DB に依存しない純粋な計算部分を検証する。
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
