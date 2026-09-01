require "test_helper"

# 振込先(口座)バグの再発防止:
# InvoiceSetting の既定 bank_info は「空」でなければならない。
# 以前は ENV["DEFAULT_BANK_INFO"](=管理者=西野の口座)を継承していたため、
# 須崎さん等の請求書の振込先が西野の口座になっていた。
class InvoiceSettingTest < Minitest::Test
  def test_default_bank_info_is_blank_for_all_categories
    %w[wings living resystems techleaders video].each do |category|
      defaults = InvoiceSetting.defaults_for(category)
      assert defaults[:bank_info].to_s.strip.empty?,
        "category=#{category} の既定 bank_info が空でない: #{defaults[:bank_info].inspect}(他人の口座を継承している恐れ)"
    end
  end

  def test_default_does_not_leak_admin_bank_via_env
    # ENV に値が入っていても既定には反映されない(個人情報は継承しない)
    refute_includes InvoiceSetting::DEFAULTS[:bank_info].to_s, "東京ベイ"
  end

  # 超過時給(残業)の既定 = 日給 ÷ 所定時間 × 1.25(労基法の時間外割増)。
  # 日給 17,000 / 8h → 基礎時給 2,125 × 1.25 = 2,656.25 → 2,656 円
  def test_default_overtime_unit_price_is_daily_rate_per_hour_with_25_percent_premium
    setting = InvoiceSetting.new(category: "transport", pay_type: "daily", daily_rate: 17_000)
    assert_equal 2_656, setting.default_overtime_unit_price

    setting.standard_hours = 10
    assert_equal 2_125, setting.default_overtime_unit_price
  end

  def test_default_overtime_unit_price_is_nil_without_daily_rate
    assert_nil InvoiceSetting.new(category: "transport", pay_type: "daily").default_overtime_unit_price
  end

  # 入力があればそれを使い、未入力(nil/0)なら既定値に落ちる。0 円で残業が無料になってはいけない
  def test_effective_overtime_unit_price_prefers_explicit_value_then_default
    setting = InvoiceSetting.new(category: "transport", pay_type: "daily", daily_rate: 17_000)
    assert_equal 2_656, setting.effective_overtime_unit_price

    setting.overtime_unit_price = 0
    assert_equal 2_656, setting.effective_overtime_unit_price

    setting.overtime_unit_price = 3_000
    assert_equal 3_000, setting.effective_overtime_unit_price
  end

  # 発行者の身元情報(インボイス番号/氏名/住所/連絡先)も他人(西野)の既定を継承しない
  def test_identity_defaults_are_blank
    %i[registration_no issuer_name postal_code address tel email].each do |key|
      %w[wings living resystems techleaders video].each do |category|
        assert InvoiceSetting.defaults_for(category)[key].to_s.strip.empty?,
          "category=#{category} の既定 #{key} が空でない(西野の身元情報を継承している恐れ)"
      end
    end
  end

  # 注文書(PO)の期間が切れている月のフォールバック時給。
  # ラボップ宛(統合請求書)の時給。川村さんへ発行する注文書の 3,250 円とは別物で、
  # 川村さんのレートは purchase_order_settings.rate_per_hour が持つ。
  def test_category_default_unit_price
    assert_equal 3750, InvoiceSetting.default_unit_price_for("living")
    assert_equal 3750, InvoiceSetting.default_unit_price_for("wings")
  end

  # 時給の概念が無いカテゴリは 0(時給行を作らない)
  def test_category_default_unit_price_is_zero_for_non_hourly_categories
    %w[resystems techleaders video].each do |category|
      assert_equal 0, InvoiceSetting.default_unit_price_for(category), "category=#{category}"
    end
  end
end
