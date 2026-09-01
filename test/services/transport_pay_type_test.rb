require "test_helper"

# 運送(transport)の報酬形態。時給と日給(+所定時間超過分の残業)を設定で切り替えられる。
class TransportPayTypeTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "pay_type_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "運送 太郎",
                         closing_day: 31, work_categories: [ "transport" ])
    @setting = @user.invoice_setting_for("transport")
    @setting.assign_attributes(client_name: "HAUKUR運送", honorific: "御中", item_label: "運送業務",
                               tax_rate: 10, issuer_name: "運送 太郎")
    @setting.save!
    # 9/1 = 10時間 / 9/2 = 8時間 / 9/3 = 6時間 → 合計24時間・稼働3日
    create_report(1, "08:00", "18:00")
    create_report(2, "08:00", "16:00")
    create_report(3, "09:00", "15:00")
  end

  def teardown
    @user&.destroy
  end

  def create_report(day, clock_in, clock_out)
    @user.work_reports.create!(work_date: Date.new(2026, 9, day), category: "transport",
                               clock_in: clock_in, clock_out: clock_out)
  end

  def calculation
    InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").calculation
  end

  def test_hourly_is_hours_times_unit_price
    @setting.update!(pay_type: "hourly", unit_price: 2_000)

    data = calculation

    assert_equal 24.0, data[:hours]
    assert_equal 1, data[:items].size
    assert_equal 48_000, data[:subtotal], "24時間 × 2,000円"
    assert_equal 52_800, data[:total]
  end

  # 日給 15,000円 / 所定8時間 / 超過時給 2,500円
  # 稼働3日 = 45,000円、超過は 9/1 の 2時間だけ = 5,000円
  def test_daily_adds_overtime_over_standard_hours
    @setting.update!(pay_type: "daily", daily_rate: 15_000, standard_hours: 8, overtime_unit_price: 2_500)

    data = calculation

    assert_equal 2, data[:items].size
    daily_row, overtime_row = data[:items]

    assert_equal 3, daily_row[:qty]
    assert_equal "日", daily_row[:unit]
    assert_equal 45_000, daily_row[:amount]

    assert_equal 2, overtime_row[:qty], "8時間を超えた分だけを日ごとに足す"
    assert_equal "時間", overtime_row[:unit]
    assert_equal 5_000, overtime_row[:amount]

    assert_equal 50_000, data[:subtotal]
    assert_equal 55_000, data[:total]
  end

  # 所定時間を超える日が無ければ残業行は出さない
  def test_daily_without_overtime
    @setting.update!(pay_type: "daily", daily_rate: 15_000, standard_hours: 10, overtime_unit_price: 2_500)

    data = calculation

    assert_equal 1, data[:items].size
    assert_equal 45_000, data[:subtotal]
  end

  # 所定時間の未設定は 8 時間として扱う
  def test_standard_hours_defaults_to_eight
    @setting.update!(pay_type: "daily", daily_rate: 15_000, standard_hours: nil, overtime_unit_price: 1_000)

    data = calculation

    assert_equal 2, data[:items].size
    assert_equal 2, data[:items].last[:qty]
  end

  # 未設定(nil)は従来どおり時給
  def test_pay_type_defaults_to_hourly
    @setting.update!(pay_type: nil, unit_price: 1_500)

    assert_equal "hourly", @setting.reload.effective_pay_type
    assert_equal 36_000, calculation[:subtotal]
  end

  # 日給+残業のときは数量列に単位を出す(日と時間が混ざるため)
  def test_html_shows_units_when_rows_are_mixed
    @setting.update!(pay_type: "daily", daily_rate: 15_000, standard_hours: 8, overtime_unit_price: 2_500)

    html = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").build_html

    assert_includes html, "数量"
    assert_includes html, "3日"
    assert_includes html, "2時間"
    assert_includes html, "時間外(8時間超過分)"
    assert_includes html, "55,000"
  end
end
