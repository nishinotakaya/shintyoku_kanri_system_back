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
  # living は注文書を 3,250 円で発行しているのに既定が 3,750 円のままだったため、
  # 注文書が引けない月(2026年7・8月分)の請求書が 3,750 円で出ていた。
  def test_category_default_unit_price
    assert_equal 3250, InvoiceSetting.default_unit_price_for("living")
    assert_equal 3750, InvoiceSetting.default_unit_price_for("wings")
  end

  # 時給の概念が無いカテゴリは 0(時給行を作らない)
  def test_category_default_unit_price_is_zero_for_non_hourly_categories
    %w[resystems techleaders video].each do |category|
      assert_equal 0, InvoiceSetting.default_unit_price_for(category), "category=#{category}"
    end
  end
end
