require_relative "../test_helper"

# 基礎控除(タックスアンサーNo.1199)の帯テーブルのテスト。DB に依存しない純粋な計算部分を検証する。
# 令和7・8年分(2025・2026)は上乗せ特例で帯が細かく、令和9年分以後は縮み、令和6年分以前は一律48万(〜2,400万)。
class OfficialTaxFormRendererBasicDeductionTest < Minitest::Test
  def deduction(year, total_income)
    renderer = OfficialTaxFormRenderer.allocate
    renderer.instance_variable_set(:@year, year)
    renderer.send(:basic_deduction_for, total_income)
  end

  def test_reiwa7_8_tiers
    assert_equal 950_000, deduction(2026, 1_320_000)   # 132万円以下
    assert_equal 880_000, deduction(2026, 2_470_278)   # 132万超336万以下(2026-08-23本番で68万と誤計算していた帯)
    assert_equal 880_000, deduction(2026, 3_360_000)
    assert_equal 680_000, deduction(2026, 4_000_000)   # 336万超489万以下
    assert_equal 630_000, deduction(2026, 5_000_000)   # 489万超655万以下
    assert_equal 580_000, deduction(2026, 8_000_000)   # 655万超2,350万以下
    assert_equal 480_000, deduction(2026, 23_800_000)  # 2,350万超2,400万以下
    assert_equal 320_000, deduction(2025, 24_200_000)
    assert_equal 160_000, deduction(2025, 24_800_000)
    assert_equal 0, deduction(2025, 26_000_000)        # 2,500万超
  end

  def test_reiwa9_and_later_drops_the_extra_tiers
    assert_equal 950_000, deduction(2027, 1_000_000)
    assert_equal 580_000, deduction(2027, 2_470_278)   # 132万超は一律58万(〜2,350万)
    assert_equal 580_000, deduction(2027, 8_000_000)
    assert_equal 480_000, deduction(2027, 23_800_000)
  end

  def test_reiwa6_and_before_is_flat_480k
    assert_equal 480_000, deduction(2024, 2_470_278)
    assert_equal 480_000, deduction(2024, 8_000_000)
    assert_equal 320_000, deduction(2024, 24_200_000)
  end
end
