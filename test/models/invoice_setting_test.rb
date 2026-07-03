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
end
