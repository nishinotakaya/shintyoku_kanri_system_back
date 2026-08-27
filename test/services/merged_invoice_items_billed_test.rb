require "test_helper"

# MergedInvoiceItems の「統合時給モード」(build_billed)。
# ラボップ宛の統合請求書は、支払側の申請額(注文書レート)ではなく
# 人ごとに設定した請求時給(merged_unit_price) × 稼働時間 で組む。
# 例: 川村さん wings は支払 2,875円/h だが請求は 3,500円/h。
class MergedInvoiceItemsBilledTest < Minitest::Test
  def setup
    @admin = User.create!(email: "billed_admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @partner = User.create!(email: "billed_partner_#{SecureRandom.hex(4)}@example.com",
                            password: "password123", display_name: "川村 卓也", closing_day: 25)
  end

  def teardown
    [ @admin, @partner ].compact.each do |user|
      InvoiceSubmission.where(user_id: user.id).delete_all
      WorkReport.where(user_id: user.id).delete_all
      InvoiceSetting.where(user_id: user.id).delete_all
      user.destroy
    end
  end

  # 2026/7 締(6/26〜7/25)に稼働を積む
  def add_hours(user, total, category: "wings")
    date = Date.new(2026, 6, 26)
    added = 0.0
    while added < total
      chunk = [ 8.0, total - added ].min
      WorkReport.create!(user: user, work_date: date, hours: chunk, category: category)
      added += chunk
      date += 1
    end
  end

  def make_sub(user, total_override:, category: "wings")
    InvoiceSubmission.create!(user: user, year: 2026, month: 7, category: category,
                              kind: "invoice", status: "approved", total_override: total_override)
  end

  # 1. merged_unit_price を設定した人は、その時給 × 稼働時間で明細が組まれる。
  #    支払側の確定額(total_override)には引きずられない。
  def test_uses_merged_unit_price_instead_of_confirmed_total
    add_hours(@partner, 145)
    setting = @partner.invoice_setting_for("wings")
    setting.update!(merged_unit_price: 3500, unit_price: 2875, item_label: "開発支援業務")
    sub = make_sub(@partner, total_override: 458_425) # 145h × 2,875円 × 1.1 = 支払額

    items = MergedInvoiceItems.build_billed([ sub ])
    hour_item = items.find { |item| item[:unit] == "時間" }

    assert_equal 3500, hour_item[:unit_price], "請求時給(3,500円)を使う。支払時給(2,875円)ではない"
    assert_equal 145, hour_item[:qty]
    assert_equal 507_500, hour_item[:amount], "145h × 3,500円"
    assert_includes hour_item[:label], "川村 卓也"
    refute items.any? { |item| item[:label] == "調整額" }, "統合時給モードでは調整額行を作らない"
  end

  # 2. シェアラウンジ利用料などの固定行(控除)は統合請求にもそのまま載る。
  def test_keeps_default_items_as_separate_rows
    add_hours(@admin, 158)
    setting = @admin.invoice_setting_for("wings")
    setting.update!(merged_unit_price: 3750, item_label: "開発支援業務",
                    default_items: [ { "label" => "シェアラウンジ利用料", "qty" => 1, "unit" => "回", "price" => -30_000 } ])
    sub = make_sub(@admin, total_override: 619_300)

    items = MergedInvoiceItems.build_billed([ sub ])

    assert_equal 2, items.size
    deduction = items.last
    assert_equal "西野 鷹也 シェアラウンジ利用料", deduction[:label]
    assert_equal(-30_000, deduction[:amount])
    assert_equal 592_500 - 30_000, items.sum { |item| item[:amount] }
  end

  # 3. 統合合計は「明細合計(税抜) + 税」。個別申請の確定額の合計ではない。
  def test_billed_total_is_built_from_billed_items
    add_hours(@admin, 158)
    add_hours(@partner, 145)
    @admin.invoice_setting_for("wings").update!(merged_unit_price: 3750, item_label: "開発支援業務", default_items: [])
    @partner.invoice_setting_for("wings").update!(merged_unit_price: 3500, item_label: "開発支援業務", default_items: [])
    subs = [ make_sub(@admin, total_override: 1), make_sub(@partner, total_override: 2) ]

    subtotal = 158 * 3750 + 145 * 3500 # 592,500 + 507,500 = 1,100,000
    assert_equal((subtotal * 1.1).round, MergedInvoiceItems.billed_total(subs))
  end

  # 4. 手編集した明細(items_override)は統合時給より優先される。
  def test_items_override_wins_over_billed_rate
    add_hours(@partner, 145)
    @partner.invoice_setting_for("wings").update!(merged_unit_price: 3500, default_items: [])
    sub = make_sub(@partner, total_override: 100_000)
    sub.update!(items_override: [ { "label" => "特別対応", "qty" => 1, "unit" => "式",
                                    "unit_price" => 200_000, "amount" => 200_000 } ])

    items = MergedInvoiceItems.build_billed([ sub ])

    assert_equal 1, items.size
    assert_equal 200_000, items.first[:amount]
  end

  # 5. 稼働が無い月は統合時給モードを使わず、従来どおり確定額ベースの1式行に落ちる。
  def test_falls_back_when_no_hours
    @partner.invoice_setting_for("wings").update!(merged_unit_price: 3500, default_items: [])
    sub = make_sub(@partner, total_override: 110_000)

    items = MergedInvoiceItems.build_billed([ sub ])

    assert_equal 1, items.size
    assert_equal "式", items.first[:unit]
    assert_equal 100_000, items.first[:amount], "確定額(税抜)を1式に集約"
  end

  # 6. 請求時給の解決順: merged_unit_price > (admin のみ)自分の unit_price > カテゴリ既定
  def test_billing_unit_price_resolution
    @partner.invoice_setting_for("wings").update!(merged_unit_price: 3600, unit_price: 2875)
    assert_equal 3600, InvoiceSetting.billing_unit_price_for(@partner, "wings")

    @partner.invoice_setting_for("wings").update!(merged_unit_price: nil)
    assert_equal 3750, InvoiceSetting.billing_unit_price_for(@partner, "wings"),
                 "非adminは自分の unit_price(支払レート)を請求に流用しない"

    @admin.invoice_setting_for("wings").update!(merged_unit_price: nil, unit_price: 3900)
    assert_equal 3900, InvoiceSetting.billing_unit_price_for(@admin, "wings"),
                 "admin は自分の unit_price が売りレート"
  end
end
