require "test_helper"

# インボイス番号(登録番号)は請求書単体の上書き(registration_no_override)があれば優先し、
# 無ければ発行者設定(_issuer_setting.registration_no)を使うこと。
class InvoiceRegistrationTemplateTest < Minitest::Test
  def test_registration_uses_override_when_present
    src = File.read(Rails.root.join("app/views/invoices/invoice.html.erb"))
    line = src[/適格請求書発行事業者登録番号.*?<div>(.*?)<\/div>/m, 1].to_s
    assert_includes line, "registration_no_override", "登録番号が請求書単体の上書きを参照していない"
    assert_includes line, "_issuer_setting.registration_no", "上書きが無いときの設定値フォールバックが無い"
  end
end
