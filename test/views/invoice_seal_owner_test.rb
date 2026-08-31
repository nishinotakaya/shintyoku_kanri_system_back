require "test_helper"
require "erb"
require "base64"

# ファイル印鑑(public/hanko_*.png)の持ち主判定。
# 以前は苗字「西野」で選んでいたため、同姓の別人(西野 雄太郎)の請求書に
# 西野 鷹也の印鑑が押されてしまった。氏名の完全一致でだけ押すことを固定する。
class InvoiceSealOwnerTest < Minitest::Test
  INVOICE_TEMPLATE = Rails.root.join("app/views/invoices/invoice.html.erb")
  EXPENSE_TEMPLATE = Rails.root.join("app/views/invoices/expense.html.erb")
  PO_TEMPLATE      = Rails.root.join("app/views/invoices/purchase_order.html.erb")
  NISHINO_HANKO    = Base64.strict_encode64(File.binread(Rails.root.join("public/hanko_nishino.png")))[0, 48]

  def setup
    @users = []
  end

  def teardown
    @users.each(&:destroy)
  end

  def create_user(display_name)
    user = User.create!(email: "seal_#{SecureRandom.hex(4)}@example.com", password: "password123",
                        display_name: display_name, closing_day: 25)
    user.invoice_setting_for("wings").update!(issuer_name: display_name, bank_info: "テスト銀行 普通 0000000")
    @users << user
    user
  end

  # 西野 鷹也 本人の請求書には従来どおり印鑑が付く(回帰防止)
  def test_nishino_takaya_invoice_has_file_seal
    html = render_invoice(create_user("西野 鷹也"))
    assert_includes html, NISHINO_HANKO
  end

  # 同姓の別人には西野 鷹也の印鑑を押さない
  def test_same_surname_other_person_has_no_nishino_seal
    html = render_invoice(create_user("西野 雄太郎"))
    refute_includes html, NISHINO_HANKO, "西野 雄太郎の請求書に西野 鷹也の印鑑が押されている"
  end

  # 注文書は発行者(代表者)名で判定する。空白なし表記の本人は一致、同姓の別人は不一致
  def test_purchase_order_matches_representative_by_full_name
    assert_includes render_po("西野鷹也"), NISHINO_HANKO, "空白なし表記の本人には押す"
    refute_includes render_po("西野 雄太郎"), NISHINO_HANKO
  end

  private

  def render_invoice(user)
    setting = user.invoice_setting_for("wings")
    client_name = "株式会社テスト"
    honorific = "御中"
    registration_no_override = nil
    bank_info_text = setting.bank_info
    title_text = "請求書"
    hanko_src = nil
    data = {
      items: [ { label: "テスト", qty: 1, unit: "式", unit_price: 1000, amount: 1000 } ],
      subtotal: 1000, total: 1000, title_text: title_text,
      issue_date: Date.new(2026, 8, 31), due_date: Date.new(2026, 9, 30),
      invoice_no: "202608310001", application_date: Date.new(2026, 8, 31)
    }
    ERB.new(File.read(INVOICE_TEMPLATE)).result(binding)
  end

  def render_po(representative)
    data = {
      order_date: "2026-08-31", order_no: "ORD-TEST", subject: "テスト",
      recipient: { name: "相手", postal_code: "", address: "" },
      issuer: { company_name: "", representative: representative, postal_code: "", address: "" },
      items: [], subtotal: 0, tax: 0, total: 0,
      delivery_deadline: "", delivery_location: "", payment_method: "", remarks: ""
    }
    ERB.new(File.read(PO_TEMPLATE)).result_with_hash(data: data)
  end
end
