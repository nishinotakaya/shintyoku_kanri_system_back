require "test_helper"

# 運送(transport)の請求書。取引先の紙の様式に合わせて
# 「日数 × 単価」の明細 + 立替金の表 + 口座欄 を出す専用テンプレートを使う。
# 他カテゴリ(wings/living 等)は従来のテンプレートのままであること。
class TransportInvoiceTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "transport_invoice_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "運送 太郎",
                         closing_day: 31, work_categories: [ "transport" ])
    setting = @user.invoice_setting_for("transport")
    setting.assign_attributes(client_name: "HAUKUR運送", honorific: "御中", subject: "9月度 配送業務",
                              item_label: "運送業務", unit_price: 2_000, tax_rate: 10,
                              issuer_name: "運送 太郎", address: "東京都墨田区押上1-1-1", tel: "090-0000-0000",
                              bank_info: "東京ベイ信用金庫 本店\n普通 1234567\nウンソウ タロウ")
    setting.save!
    # 稼働3日(開始・終了そろっている日だけ数える) + 立替金2件
    [ 1, 2, 3 ].each do |day|
      @user.work_reports.create!(work_date: Date.new(2026, 9, day), category: "transport",
                                 clock_in: "08:00", clock_out: "18:00", distance_km: 120)
    end
    @user.work_reports.create!(work_date: Date.new(2026, 9, 4), category: "transport", note: "待機のみ")
    @user.expenses.create!(expense_date: Date.new(2026, 9, 1), category: "transport",
                           purpose: "高速代", amount: 1_200, receipt_no: "無")
    @user.expenses.create!(expense_date: Date.new(2026, 9, 2), category: "transport",
                           purpose: "駐車場代", amount: 500, receipt_no: "無")
  end

  def teardown
    @user&.destroy
  end

  # 稼働時間 × 時給。10時間 × 3日 = 30時間 → 30 × 2,000 = 60,000(税抜)
  def test_items_are_hours_times_hourly_rate
    data = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").calculation

    assert_equal 3, data[:worked_days], "開始・終了がそろった日だけ稼働日数に数える"
    assert_equal 30.0, data[:hours], "開始・終了から自動計算した稼働時間の合計"
    assert_equal 1, data[:items].size
    item = data[:items].first
    assert_equal 30, item[:qty]
    assert_equal "時間", item[:unit]
    assert_equal 2_000, item[:unit_price]
    assert_equal 60_000, item[:amount]
    assert_equal 60_000, data[:subtotal]
    assert_equal 6_000, data[:tax]
    assert_equal 66_000, data[:total]
  end

  # 30分単位の端数も金額に乗る(9.5時間 × 2,000 = 19,000)
  def test_fractional_hours
    @user.work_reports.where(work_date: Date.new(2026, 9, 2)).destroy_all
    @user.work_reports.where(work_date: Date.new(2026, 9, 3)).destroy_all
    @user.work_reports.find_by(work_date: Date.new(2026, 9, 1)).update!(clock_out: "17:30")

    data = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").calculation
    item = data[:items].first

    assert_equal 9.5, data[:hours]
    assert_equal 9.5, item[:qty]
    assert_equal 19_000, item[:amount]
    assert_equal 1_900, data[:tax]
    assert_equal 20_900, data[:total]
  end

  # 申請を作った時点で稼働時間が 0 だった等で total_override に 0 が入っていても、
  # 明細だけ 20,000 円で 小計・合計が 0 になる、という食い違いを起こさない
  # 日給で超過時給が未入力なら、日給 ÷ 所定時間 × 1.25 を使う(0 円で残業が無料になってはいけない)。
  # 日給 17,000 × 3日 = 51,000 ＋ 超過 (10h−8h) × 3日 = 6h × 2,656 = 15,936 → 66,936(税抜)
  def test_daily_pay_falls_back_to_default_overtime_unit_price
    @user.invoice_setting_for("transport").update!(pay_type: "daily", daily_rate: 17_000, overtime_unit_price: nil)

    calc = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").calculation
    daily_row, overtime_row = calc[:items]

    assert_equal 3, daily_row[:qty]
    assert_equal 17_000, daily_row[:unit_price]
    assert_equal 2_656, overtime_row[:unit_price]
    assert_equal 15_936, overtime_row[:amount]
    assert_equal 66_936, calc[:subtotal]
  end

  # 税込(内税)設定: 明細の金額が税込。合計=明細合計、税抜小計=合計÷1.1(四捨五入)、消費税=差額。
  # 時給 2,000(税込) × 30h = 60,000(税込) → 小計 54,545 / 内消費税 5,455 / 合計 60,000
  def test_tax_included_setting_treats_item_amounts_as_tax_inclusive
    @user.invoice_setting_for("transport").update!(tax_included: true)

    calc = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").calculation

    assert calc[:tax_included]
    assert_equal 60_000, calc[:total]
    assert_equal 54_545, calc[:subtotal]
    assert_equal 5_455, calc[:tax]

    html = render_invoice_html
    assert_includes html, "内 消 費 税", "税込のときは消費税を内税として出す"
    assert_includes html, "単価(税込)"
    assert_includes html, "合　計（税込）"
  end

  # 代理発行(支払通知書)の税込/税抜は発行者の設定に従う。
  # 雄太郎(税込)が外注ドライバー(設定は既定=税抜)へ出す支払通知書は税込で計算される
  def test_payment_notice_follows_the_issuer_tax_setting
    owner = User.create!(email: "transport_owner_#{SecureRandom.hex(4)}@example.com", password: "password123",
                         display_name: "西野 雄太郎", closing_day: 31, work_categories: [ "transport" ])
    owner.invoice_setting_for("transport").tap { |s| s.tax_included = true; s.save! }

    calc = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport",
                                  issuer_user_override: owner, title_override: "支払通知書").calculation

    assert calc[:tax_included]
    assert_equal 60_000, calc[:total]
    assert_equal 5_455, calc[:tax]
  ensure
    owner&.destroy
  end

  # テナントのメンバー(外注ドライバー)は、代表の税込/税抜を既定として引き継ぐ
  def test_tenant_member_inherits_tax_included_from_the_owner
    owner = User.create!(email: "transport_owner_#{SecureRandom.hex(4)}@example.com", password: "password123",
                         display_name: "西野 雄太郎", closing_day: 31, work_categories: [ "transport" ])
    owner.invoice_setting_for("transport").tap { |s| s.tax_included = true; s.save! }
    tenant = Tenant.create!(name: "HAUKUR運送 #{SecureRandom.hex(3)}", code: "haukur-#{SecureRandom.hex(3)}", owner_user: owner)
    driver = User.create!(email: "transport_driver_#{SecureRandom.hex(4)}@example.com", password: "password123",
                          display_name: "外注 一郎", closing_day: 31, work_categories: [ "transport" ])
    TenantMembership.create!(tenant: tenant, user: driver)

    assert driver.invoice_setting_for("transport").tax_included?, "メンバーは代表の税込を引き継ぐ"
    refute owner.invoice_setting_for("wings").tax_included?, "代表本人・別カテゴリには影響しない"
  ensure
    tenant&.destroy
    driver&.destroy
    owner&.destroy
  end

  # 既定(税抜)では従来どおり明細合計に消費税を加算する(西野・川村の請求書は変わらない)
  def test_tax_excluded_is_the_default_and_adds_tax_on_top
    calc = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").calculation

    refute calc[:tax_included]
    assert_equal 60_000, calc[:subtotal]
    assert_equal 6_000, calc[:tax]
    assert_equal 66_000, calc[:total]
    refute_includes render_invoice_html, "内 消 費 税"
  end

  def test_zero_total_override_is_treated_as_unset
    data = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport",
                                  total_override: 0).calculation

    assert_equal 60_000, data[:subtotal]
    assert_equal 66_000, data[:total]
  end

  # 明示された税込合計(0以外)は従来どおり最優先
  def test_positive_total_override_still_wins
    data = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport",
                                  total_override: 33_000).calculation

    assert_equal 33_000, data[:total]
    assert_equal 30_000, data[:subtotal]
  end

  def test_html_follows_the_paper_form
    html = render_invoice_html

    assert_includes html, "請 求 書"
    assert_includes html, "日締め分"
    assert_includes html, "HAUKUR運送"
    assert_includes html, "ご請求金額"
    assert_includes html, "立替金"
    assert_includes html, "高速代"
    assert_includes html, "駐車場代"
    assert_includes html, "1,700",   "立替金の合計を出す"
    assert_includes html, "金融機関"
    assert_includes html, "口座名義"
    assert_includes html, "ウンソウ タロウ"
    assert_includes html, "時間数", "時給×稼働時間なので列見出しは「時間数」"
    assert_includes html, "66,000"
  end

  # 他カテゴリは従来のテンプレート(運送専用の項目が出ない)
  def test_other_categories_keep_the_existing_template
    renderer = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "wings")

    assert_equal InvoicePdfRenderer::TEMPLATE, renderer.send(:template_path)
  end

  private

  # PDF 化(Playwright)まではせず、テンプレートの HTML だけを組み立てて確認する
  def render_invoice_html
    renderer = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport")
    assert_equal InvoicePdfRenderer::TRANSPORT_TEMPLATE, renderer.send(:template_path)

    renderer.build_html
  end
end
