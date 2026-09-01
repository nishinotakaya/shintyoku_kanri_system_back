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
                              item_label: "運送業務", unit_price: 17_000, tax_rate: 10,
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

  def test_items_are_days_times_daily_rate
    data = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").calculation

    assert_equal 3, data[:worked_days], "開始・終了がそろった日だけ稼働日数に数える"
    assert_equal 1, data[:items].size
    item = data[:items].first
    assert_equal 3, item[:qty]
    assert_equal "日", item[:unit]
    assert_equal 17_000, item[:unit_price]
    assert_equal 51_000, item[:amount]
    assert_equal 51_000, data[:subtotal]
    assert_equal 5_100, data[:tax]
    assert_equal 56_100, data[:total]
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
    assert_includes html, "56,100"
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

    data = renderer.calculation
    setting = @user.invoice_setting_for("transport")
    user = @user
    client_name = setting.client_name
    honorific = setting.honorific
    subject_text = setting.subject
    note_text = nil
    bank_info_text = setting.bank_info
    advanced_expenses = renderer.send(:transport_expenses)
    ERB.new(File.read(InvoicePdfRenderer::TRANSPORT_TEMPLATE)).result(binding)
  end
end
