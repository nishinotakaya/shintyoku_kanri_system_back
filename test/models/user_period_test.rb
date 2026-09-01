require "test_helper"

# 締日ベースの対象期間(User#period_for)。25日締め(西野さん・川村さん)と
# 末日締め(運送の雄太郎さん。契約書第10条が毎月末日締切)の両方を守る。
class UserPeriodTest < ActiveSupport::TestCase
  def test_period_for_with_closing_day_25
    user = User.new(closing_day: 25)

    assert_equal Date.new(2026, 8, 26)..Date.new(2026, 9, 25), user.period_for(2026, 9)
    assert_equal Date.new(2026, 1, 26)..Date.new(2026, 2, 25), user.period_for(2026, 2)
  end

  def test_period_for_defaults_to_25_when_closing_day_is_missing
    user = User.new(closing_day: nil)

    assert_equal Date.new(2026, 8, 26)..Date.new(2026, 9, 25), user.period_for(2026, 9)
  end

  # 31日締めは「末日締め」。前月の方が日数が多い月(9月度など)で開始日が
  # 前月末日にずれないこと(2026-08-31 ではなく 2026-09-01 から始まる)。
  def test_period_for_with_end_of_month_closing_day
    user = User.new(closing_day: 31)

    assert_equal Date.new(2026, 9, 1)..Date.new(2026, 9, 30), user.period_for(2026, 9)
    assert_equal Date.new(2026, 8, 1)..Date.new(2026, 8, 31), user.period_for(2026, 8)
    assert_equal Date.new(2026, 2, 1)..Date.new(2026, 2, 28), user.period_for(2026, 2)
    assert_equal Date.new(2028, 2, 1)..Date.new(2028, 2, 29), user.period_for(2028, 2)
  end

  # 締日が月末日を超える月は月末日に丸める(30日締めの2月など)。
  def test_period_for_clamps_closing_day_to_last_day_of_month
    user = User.new(closing_day: 30)

    # 1月度は 1/30 で終わるので 2月度は 1/31 から。2月度は月末日に丸めて 2/28 で終わる。
    assert_equal Date.new(2026, 1, 31)..Date.new(2026, 2, 28), user.period_for(2026, 2)
    # その2月度が 2/28 で終わっているので、3月度は 3/1 から始まる(2/28 を二重に数えない)。
    assert_equal Date.new(2026, 3, 1)..Date.new(2026, 3, 30), user.period_for(2026, 3)
  end
end
