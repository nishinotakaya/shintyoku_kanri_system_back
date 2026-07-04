require_relative "../test_helper"
require "json"

# 確定申告/消費税PDFのコーム(1マス1桁)レイアウトと桁割りのテスト。
# 生成済み .tlf が座標マスタ(TaxFormTlfLayouts)と同期しているかも検証する
# （レイアウト変更後に script/build_tax_form_tlfs.rb を回し忘れると落ちる）。
class TaxFormTlfLayoutsTest < Minitest::Test
  COMB_PAGES = %i[shinkokusho_p1 shohi_p1 shohi_p2 kessansho_p1 kessansho_p2].freeze

  # ============ 桁割り (comb_digits) ============

  def test_comb_digits_fills_from_rightmost_cell
    values = TaxFormTlfLayouts.comb_digits(:shohi_p1, :taxable_base, 6_616_000)
    assert_equal "0", values[:taxable_base_d0]   # 一円マス
    assert_equal "0", values[:taxable_base_d1]
    assert_equal "0", values[:taxable_base_d2]
    assert_equal "6", values[:taxable_base_d3]
    assert_equal "6", values[:taxable_base_d6]   # 最上位桁
    assert_nil values[:taxable_base_d7]          # 桁が無いマスは書かない
    assert_nil values[:taxable_base_ov]
  end

  def test_comb_digits_zero_prints_single_zero
    values = TaxFormTlfLayouts.comb_digits(:shohi_p1, :taxable_base, 0)
    assert_equal({ taxable_base_d0: "0" }, values)
  end

  def test_comb_digits_respects_preprinted_skip
    # ㉛課税所得は下3桁000がプレ印字 → 千円単位の値が d0(=右から4マス目)から入る
    spec = TaxFormTlfLayouts.comb(:shinkokusho_p1, :taxable_thousand)
    assert_equal 3, spec[:skip]
    values = TaxFormTlfLayouts.comb_digits(:shinkokusho_p1, :taxable_thousand, 3895)
    assert_equal "5", values[:taxable_thousand_d0]
    assert_equal "3", values[:taxable_thousand_d3]
    assert_nil values[:taxable_thousand_d4]
  end

  def test_comb_digits_overflows_to_wide_cell
    # 第一表右列は7マス(skip 0)。8桁を超えた上位桁は幅広マス(_ov)へ
    values = TaxFormTlfLayouts.comb_digits(:shinkokusho_p1, :tax_32, 123_456_789)
    assert_equal "9", values[:tax_32_d0]
    assert_equal "3", values[:tax_32_d6]
    assert_equal "12", values[:tax_32_ov]
  end

  def test_comb_digits_raises_for_unknown_id
    assert_raises(ArgumentError) { TaxFormTlfLayouts.comb_digits(:shohi_p1, :unknown_field, 1) }
  end

  # ============ コーム定義の整合性 ============

  def test_comb_cells_stay_inside_page
    COMB_PAGES.each do |page_key|
      TaxFormTlfLayouts.pages.fetch(page_key)[:combs].each do |comb|
        leftmost = comb[:x_right] - (comb[:cells] - 1) * comb[:pitch]
        assert leftmost > 0, "#{page_key}/#{comb[:id]} の左端マスがページ外"
        assert comb[:x_right] < 100
        assert (0..100).cover?(comb[:y]), "#{page_key}/#{comb[:id]} の y が範囲外"
      end
    end
  end

  # ============ 生成済み .tlf との同期 ============

  def test_generated_tlf_contains_per_digit_items
    COMB_PAGES.each do |page_key|
      item_ids = tlf_item_ids(page_key)
      TaxFormTlfLayouts.pages.fetch(page_key)[:combs].each do |comb|
        fillable = comb[:cells] - comb.fetch(:skip, 0)
        fillable.times do |i|
          assert_includes item_ids, "#{comb[:id]}_d#{i}",
            "#{page_key}.tlf に #{comb[:id]}_d#{i} が無い。script/build_tax_form_tlfs.rb を再実行すること"
        end
        assert_equal comb.key?(:overflow), item_ids.include?("#{comb[:id]}_ov"),
          "#{page_key}.tlf の #{comb[:id]}_ov の有無が定義と不一致"
      end
    end
  end

  def test_generated_tlf_digit_size_matches_master
    COMB_PAGES.each do |page_key|
      items = tlf_items(page_key)
      TaxFormTlfLayouts.pages.fetch(page_key)[:combs].each do |comb|
        item = items.find { |i| i["id"] == "#{comb[:id]}_d0" }
        expected_pt = (comb[:size] * 0.75).round(1)
        assert_in_delta expected_pt, item["style"]["font-size"], 0.05,
          "#{page_key}/#{comb[:id]} のフォントサイズが .tlf と不一致"
      end
    end
  end

  private

  def tlf_items(page_key)
    @tlf_items ||= {}
    @tlf_items[page_key] ||= JSON.parse(
      File.read(Rails.root.join("app/reports/tax_forms/tlf/#{page_key}.tlf"))
    )["items"]
  end

  def tlf_item_ids(page_key)
    tlf_items(page_key).map { |item| item["id"] }
  end
end
