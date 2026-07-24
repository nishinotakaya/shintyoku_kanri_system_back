require "test_helper"
require "erb"

# 請求書 / 立替金 / 支払通知書 PDF の「差出人ブロック(名義・住所・登録番号)」と「振込先」が
# 誰の情報になるかを検証する。
# - 請求書 / 立替金: 差出人=請求者(対象ユーザー=川村)。admin(西野)が代理発行しても西野にしない。
# - 支払通知書: 差出人=支払者(西野)、振込先=受領者(川村)。
# 回帰: 立替金/請求書で差出人ブロックと振込先が発行操作者(西野)になっていたバグ。
class InvoiceSenderIdentityTest < Minitest::Test
  EXPENSE_TEMPLATE = Rails.root.join("app/views/invoices/expense_invoice.html.erb")
  INVOICE_TEMPLATE = Rails.root.join("app/views/invoices/invoice.html.erb")

  def setup
    @payer = User.create!( # 西野(発行操作者=支払者)
      email: "sender_payer_#{SecureRandom.hex(4)}@example.com",
      password: "password123", display_name: "西野 鷹也", closing_day: 25
    )
    @biller = User.create!( # 川村(請求者=受領者)
      email: "sender_biller_#{SecureRandom.hex(4)}@example.com",
      password: "password123", display_name: "川村 卓也", closing_day: 25
    )
    @payer_setting = build_setting(@payer, issuer_name: "西野 鷹也",
      address: "千葉県松戸市六高台2丁目116", registration_no: "T1111111111111",
      bank_info: "東京ベイ信用金庫 六実支店 普通 0286190 ニシノタカヤ")
    @biller_setting = build_setting(@biller, issuer_name: "川村 卓也",
      address: "千葉県千葉市中央区白旗3-25-7", registration_no: "T2222222222222",
      bank_info: "三菱UFJ銀行 札幌中央支店 普通 0059947 カワムラタクヤ")
  end

  def teardown
    @biller&.destroy
    @payer&.destroy
  end

  # 立替金(請求書)を admin(西野)が代理発行 → 差出人も振込先も川村本人。
  def test_expense_invoice_sender_and_bank_are_biller_even_when_issued_by_admin
    html = render(EXPENSE_TEMPLATE, title_text: "請求書")

    assert_includes html, "千葉県千葉市中央区白旗3-25-7", "住所は川村(請求者)であるべき"
    assert_includes html, "カワムラタクヤ", "振込先は川村であるべき"
    assert_includes html, "T2222222222222", "登録番号は川村であるべき"
    refute_includes html, "六高台", "西野の住所が出てはいけない"
    refute_includes html, "ニシノタカヤ", "西野の振込先が出てはいけない"
    refute_includes html, "T1111111111111", "西野の登録番号が出てはいけない"
  end

  # 支払通知書は 差出人=西野(支払者)、振込先=川村(受領者)。
  def test_expense_payment_notice_sender_is_payer_and_bank_is_payee
    html = render(EXPENSE_TEMPLATE, title_text: "支払通知書")

    assert_includes html, "六高台", "差出人住所は支払者(西野)であるべき"
    assert_includes html, "T1111111111111", "差出人登録番号は支払者(西野)であるべき"
    assert_includes html, "カワムラタクヤ", "振込先は受領者(川村)であるべき"
    refute_includes html, "ニシノタカヤ", "西野の口座を振込先にしてはいけない"
  end

  # 通常の請求書(invoice.html.erb)も admin 代理発行で差出人=川村。
  def test_regular_invoice_sender_is_biller_even_when_issued_by_admin
    html = render(INVOICE_TEMPLATE, title_text: "請求書", bank_info_text: @biller_setting.bank_info)

    assert_includes html, "千葉県千葉市中央区白旗3-25-7", "住所は川村(請求者)であるべき"
    assert_includes html, "T2222222222222", "登録番号は川村であるべき"
    assert_includes html, "カワムラタクヤ", "振込先は川村であるべき"
    refute_includes html, "六高台", "西野の住所が出てはいけない"
    refute_includes html, "ニシノタカヤ", "西野の振込先が出てはいけない"
  end

  private

  def build_setting(user, issuer_name:, address:, registration_no:, bank_info:)
    setting = user.invoice_setting_for("wings")
    setting.update!(issuer_name: issuer_name, address: address, postal_code: "100-0001",
      tel: "000-0000-0000", email: user.email, registration_no: registration_no, bank_info: bank_info)
    setting
  end

  # テンプレートを、admin(西野)が川村の帳票を代理発行する状況の binding で描画する。
  def render(template, title_text:, bank_info_text: nil)
    setting = @biller_setting          # 対象ユーザー(請求者/受領者)=川村
    issuer_setting = @payer_setting    # 発行操作者(支払者)=西野
    issuer_user = @payer
    user = @biller
    client_name = "株式会社ラボップ"
    honorific = "御中"
    registration_no_override = nil
    bank_info_text ||= setting.bank_info
    hanko_src = nil
    data = {
      items: [ { label: "#{@biller.display_name} 立替金", qty: 1, unit: "式", unit_price: 1000, amount: 1000 } ],
      subtotal: 1000, total: 1000, title_text: title_text,
      issue_date: Date.new(2026, 6, 25), due_date: Date.new(2026, 7, 24),
      invoice_no: "202606250006", application_date: Date.new(2026, 6, 30)
    }
    ERB.new(File.read(template)).result(binding)
  end
end
