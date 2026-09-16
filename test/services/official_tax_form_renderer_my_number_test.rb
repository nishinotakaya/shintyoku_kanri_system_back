require_relative "../test_helper"

# 第一表・消費税第一表への個人番号(12マス)と、第一表の生年月日(元号コード+年月日)の桁割り。
# DB に依存しないよう、@user には my_number / birth_date だけ持つスタブを入れる。
class OfficialTaxFormRendererMyNumberTest < Minitest::Test
  UserStub = Struct.new(:my_number, :birth_date)

  def renderer_for(my_number:, birth_date:)
    renderer = OfficialTaxFormRenderer.allocate
    renderer.instance_variable_set(:@user, UserStub.new(my_number, birth_date))
    renderer.instance_variable_set(:@year, 2026)
    renderer
  end

  def test_my_number_fills_twelve_cells_from_the_right
    values = renderer_for(my_number: "123456789018", birth_date: nil).send(:my_number_combs, :shinkokusho_p1)

    assert_equal "8", values[:my_number_d0]   # 右端 = 12桁目
    assert_equal "1", values[:my_number_d11]  # 左端 = 1桁目
    assert_equal 12, values.keys.grep(/\Amy_number_d\d+\z/).size
    refute values.key?(:my_number_ov)
  end

  def test_my_number_is_available_on_consumption_tax_form_too
    values = renderer_for(my_number: "123456789018", birth_date: nil).send(:my_number_combs, :shohi_p1)

    assert_equal 12, values.size
  end

  def test_my_number_is_blank_when_not_registered_or_malformed
    assert_empty renderer_for(my_number: nil, birth_date: nil).send(:my_number_combs, :shinkokusho_p1)
    assert_empty renderer_for(my_number: "12345", birth_date: nil).send(:my_number_combs, :shinkokusho_p1)
  end

  # 平成2年9月30日 → 元号コード4・年02・月09・日30
  def test_birth_date_in_heisei
    values = renderer_for(my_number: nil, birth_date: Date.new(1990, 9, 30)).send(:birth_date_combs)

    assert_equal "4", values[:birth_era_d0]
    assert_equal({ d1: "0", d0: "2" }, { d1: values[:birth_year_d1], d0: values[:birth_year_d0] })
    assert_equal({ d1: "0", d0: "9" }, { d1: values[:birth_month_d1], d0: values[:birth_month_d0] })
    assert_equal({ d1: "3", d0: "0" }, { d1: values[:birth_day_d1], d0: values[:birth_day_d0] })
  end

  # 令和元年5月1日(改元日) → 元号コード5・年01
  def test_birth_date_on_first_day_of_reiwa
    values = renderer_for(my_number: nil, birth_date: Date.new(2019, 5, 1)).send(:birth_date_combs)

    assert_equal "5", values[:birth_era_d0]
    assert_equal "1", values[:birth_year_d0]
    assert_equal "0", values[:birth_year_d1]
  end

  # 昭和64年1月7日(昭和最終日) → 元号コード3・年64
  def test_birth_date_on_last_day_of_showa
    values = renderer_for(my_number: nil, birth_date: Date.new(1989, 1, 7)).send(:birth_date_combs)

    assert_equal "3", values[:birth_era_d0]
    assert_equal "4", values[:birth_year_d0]
    assert_equal "6", values[:birth_year_d1]
  end

  def test_birth_date_is_blank_when_not_registered
    assert_empty renderer_for(my_number: nil, birth_date: nil).send(:birth_date_combs)
  end
end
