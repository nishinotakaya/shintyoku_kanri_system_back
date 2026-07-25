require "test_helper"
require "erb"

# 支払通知書PDFの電子サイン(証明ブロック)描画テスト。
# e_sign が渡された時だけ「署名者/日時/検証番号」を描画し、渡されない時は描画しないことを確認する。
class InvoiceESignTest < Minitest::Test
  INVOICE_TEMPLATE = Rails.root.join("app/views/invoices/invoice.html.erb")

  def setup
    @user = User.create!(email: "esign_#{SecureRandom.hex(4)}@example.com", password: "password123",
      display_name: "川村 卓也", closing_day: 25)
    @setting = @user.invoice_setting_for("wings")
    @setting.update!(issuer_name: "川村 卓也", bank_info: "三菱UFJ銀行 普通 0059947 カワムラタクヤ")
  end

  def teardown
    @user&.destroy
  end

  def render(e_sign:)
    setting = @setting
    user = @user
    client_name = "株式会社ラボップ"; honorific = "御中"
    title_text = "支払通知書"
    bank_info_text = @setting.bank_info
    hanko_src = nil
    data = { items: [ { label: "開発業務", qty: 160, unit: "時間", unit_price: 2875, amount: 460_000 } ],
      subtotal: 460_000, tax: 46_000, tax_rate: 10, total: 506_000,
      issue_date: Date.new(2026, 7, 24), due_date: Date.new(2026, 7, 24),
      invoice_no: "x", application_date: Date.new(2026, 7, 24) }
    ERB.new(File.read(INVOICE_TEMPLATE)).result(binding)
  end

  # 1. e_sign を渡すと 署名者・検証番号・証明ブロックが描画される。
  def test_renders_esign_block_when_present
    html = render(e_sign: { signer_name: "西野 鷹也", signed_at: "2026年7月24日 10:00", verify_id: "abc123def456" })

    assert_includes html, "電子的に証明済"
    assert_includes html, "西野 鷹也"
    assert_includes html, "abc123def456"
    assert_includes html, "改ざん検知"
  end

  # 2. e_sign が無ければ証明ブロックは描画されない。
  def test_no_esign_block_when_absent
    html = render(e_sign: nil)

    refute_includes html, "電子的に証明済"
  end
end
