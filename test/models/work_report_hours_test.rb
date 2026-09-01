require "test_helper"

# 稼働時間(hours)は開始・終了時間から自動計算される。
# 打刻ボタンだけでなく、カレンダー・稼働報告書からの入力でも入ること
# (入らないと勤怠の合計稼働時間や請求金額が 0 のままになる)。
class WorkReportHoursTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "wr_hours_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "運送 太郎", closing_day: 31)
  end

  def teardown
    @user&.destroy
  end

  def create_report(**attrs)
    @user.work_reports.create!({ work_date: Date.new(2026, 9, 1), category: "transport" }.merge(attrs))
  end

  def test_hours_are_calculated_from_clock_in_and_out
    report = create_report(clock_in: "08:00", clock_out: "18:00")

    assert_equal 10.0, report.hours.to_f
  end

  def test_break_minutes_are_subtracted
    report = create_report(clock_in: "08:00", clock_out: "18:00", break_minutes: 60)

    assert_equal 9.0, report.hours.to_f
  end

  # 日をまたいだ稼働(22:00 → 06:00)は 8 時間
  def test_overnight_shift
    report = create_report(clock_in: "22:00", clock_out: "06:00")

    assert_equal 8.0, report.hours.to_f
  end

  def test_updating_the_clock_recalculates_hours
    report = create_report(clock_in: "08:00", clock_out: "18:00")
    report.update!(clock_out: "20:00")

    assert_equal 12.0, report.reload.hours.to_f
  end

  # 時間を手で直したらその値を尊重する(自動計算で上書きしない)
  def test_manual_hours_are_respected
    report = create_report(clock_in: "08:00", clock_out: "18:00")
    report.update!(hours: 7.5)

    assert_equal 7.5, report.reload.hours.to_f
  end

  def test_hours_stay_nil_without_clock_times
    report = create_report(note: "待機のみ")

    assert_nil report.hours
  end
end
