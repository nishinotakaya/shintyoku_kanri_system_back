require "test_helper"

# インボイス番号(登録番号)は請求書単体の上書き(registration_no_override)があれば優先し、
# 無ければ差出人設定(_sender_setting.registration_no)を使うこと。
# 差出人=請求者(請求書は対象ユーザー本人)であり、admin 代理発行でも操作者の番号にしない。
class InvoiceRegistrationTemplateTest < Minitest::Test
  def test_registration_uses_override_when_present
    src = File.read(Rails.root.join("app/views/invoices/invoice.html.erb"))
    line = src[/適格請求書発行事業者登録番号.*?<div>(.*?)<\/div>/m, 1].to_s
    assert_includes line, "registration_no_override", "登録番号が請求書単体の上書きを参照していない"
    assert_includes line, "_sender_setting.registration_no", "上書きが無いときの差出人設定フォールバックが無い"
  end
end
