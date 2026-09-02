require "test_helper"

# 統合請求書(ラボップ宛)の固定明細は、支払側(本人への請求書)と分けて持てること。
# 川村さんは「請求側だけシェアラウンジ控除」なので、default_items に入れると支払額まで減る。
class MergedInvoiceBillingItemsTest < Minitest::Test
  LOUNGE = { "label" => "シェアラウンジ利用料", "qty" => 1, "unit" => "回", "price" => -30000 }.freeze

  def setup
    @user = User.create!(email: "billing_items_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "請求 太郎")
  end

  def teardown
    @user&.destroy
  end

  def build_setting(default_items:, merged_default_items: nil)
    @user.invoice_settings.create!(category: "wings", item_label: "開発支援業務",
                                   default_items: default_items, merged_default_items: merged_default_items)
  end

  # 請求側専用の設定があれば、そちらが使われる(支払側は空のまま)
  def test_billing_items_prefer_merged_default_items
    build_setting(default_items: [], merged_default_items: [ LOUNGE ])

    items = InvoiceSetting.billing_default_items_for(@user, "wings")

    assert_equal 1, items.size
    assert_equal "シェアラウンジ利用料", items.first["label"]
    assert_equal "回", items.first["unit"]
  end

  # 請求側の設定が無い人(西野)は、従来どおり default_items を流用する
  def test_billing_items_fall_back_to_default_items
    build_setting(default_items: [ LOUNGE ], merged_default_items: nil)

    assert_equal [ LOUNGE ], InvoiceSetting.billing_default_items_for(@user, "wings")
  end

  def test_billing_items_are_empty_when_setting_is_missing
    assert_equal [], InvoiceSetting.billing_default_items_for(@user, "wings")
  end

  # --- 品名の無い課金行を弾くガード ---

  # 品名が空で金額があると、客先に空欄の明細が出る。発行前に検知する。
  def test_nameless_charge_row_is_detected
    rows = [ { "label" => "開発支援業務", "amount" => 100 }, { "label" => "", "amount" => -30000 } ]

    assert_equal(-30000, MergedInvoiceItems.nameless_charge_row(rows)["amount"])
  end

  # 金額 0 の空行は入力途中なので検知しない(normalize が捨てる)
  def test_blank_zero_row_is_not_treated_as_nameless_charge
    assert_nil MergedInvoiceItems.nameless_charge_row([ { "label" => "", "amount" => 0 } ])
  end

  def test_named_rows_pass
    assert_nil MergedInvoiceItems.nameless_charge_row([ { "label" => "シェアラウンジ利用料", "amount" => -30000 } ])
  end
end
