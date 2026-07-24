require "test_helper"

# InvoicePdfRenderer#calculation の明細生成テスト。
# labop モード(発行者≠申請者) + total_override あり + items_override なし のとき、
# 「請求書/支払通知書の 数量」が実働時間になり、数量×単価=金額 が実態と一致することを検証する。
# 回帰: 以前はデフォルト単価(wings=3,500)で数量を逆算し 160.0h の申請が 131.4h と表示されていた。
class InvoicePdfRendererCalculationTest < Minitest::Test
  def setup
    @issuer = User.create!( # 発行者(西野 admin 相当)
      email: "invoice_issuer_#{SecureRandom.hex(4)}@example.com",
      password: "password123", display_name: "発行 太郎", closing_day: 25
    )
    @worker = User.create!( # 申請者(川村 相当)
      email: "invoice_worker_#{SecureRandom.hex(4)}@example.com",
      password: "password123", display_name: "川村 卓也", closing_day: 25
    )
  end

  def teardown
    @worker&.destroy
    @issuer&.destroy
  end

  # 2026-06 締(5/26〜6/25)に合計160.0時間を積む。
  def create_160_hours!
    # 20営業日 × 8.0h = 160.0h
    date = Date.new(2026, 5, 26)
    added = 0.0
    while added < 160.0
      WorkReport.create!(user: @worker, work_date: date, hours: 8.0, category: "wings")
      added += 8.0
      date += 1
    end
  end

  # 1. 実働160hの労働者に総額506,000(税込)を指定 → 数量=160(整数), 単価=2,875, 金額=460,000。
  #    数量×単価が金額に一致する。
  def test_quantity_uses_actual_hours_and_unit_price_matches_amount
    create_160_hours!
    renderer = InvoicePdfRenderer.new(
      @worker, year: 2026, month: 6, category: "wings",
      issuer_user_override: @issuer, total_override: 506_000
    )
    data = renderer.calculation

    assert_equal 460_000, data[:subtotal]
    assert_equal 46_000, data[:tax]
    assert_equal 506_000, data[:total]
    assert_equal 1, data[:items].size
    item = data[:items].first
    assert_equal 160, item[:qty], "数量は実働時間(160)になるべき(131.4ではない)"
    assert_equal 2_875, item[:unit_price], "単価は税抜金額÷実働時間=2,875"
    assert_equal 460_000, item[:amount]
    assert_equal item[:qty] * item[:unit_price], item[:amount], "数量×単価が金額に一致すべき"
    assert_equal "時間", item[:unit]
  end

  # 2. 実働が0の月は従来どおりデフォルト単価から数量を逆算するフォールバックに落ちる。
  def test_falls_back_to_default_unit_price_when_no_hours
    renderer = InvoicePdfRenderer.new(
      @worker, year: 2026, month: 6, category: "wings",
      issuer_user_override: @issuer, total_override: 506_000
    )
    data = renderer.calculation

    item = data[:items].first
    refute_nil item
    # wings デフォルト単価(3,500)で 460,000÷3,500=131.4 に逆算される(実働が無い時の挙動)
    assert_equal 3_500, item[:unit_price]
    assert_in_delta 131.4, item[:qty], 0.05
  end

  # 3. 小数時間(例:131.5h)でも数量は実働時間そのまま、単価は四捨五入で金額と概ね一致する。
  def test_fractional_hours_kept_as_quantity
    date = Date.new(2026, 5, 26)
    added = 0.0
    while added < 131.5
      add = (131.5 - added) >= 8.0 ? 8.0 : (131.5 - added)
      WorkReport.create!(user: @worker, work_date: date, hours: add, category: "wings")
      added += add
      date += 1
    end
    renderer = InvoicePdfRenderer.new(
      @worker, year: 2026, month: 6, category: "wings",
      issuer_user_override: @issuer, total_override: 506_000
    )
    data = renderer.calculation

    item = data[:items].first
    assert_in_delta 131.5, item[:qty], 0.01, "数量は実働時間(131.5)のまま"
    assert_equal 460_000, item[:amount]
  end
end
