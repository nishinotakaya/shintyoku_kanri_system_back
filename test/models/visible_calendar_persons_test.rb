require "test_helper"

# カレンダーに予定行を出す人物は、管理者が /users で設定できる。
# 未設定のときの既定は「西野さん・川村さんは全員分、それ以外は自分の予定だけ」。
class VisibleCalendarPersonsTest < ActiveSupport::TestCase
  def create_user(display_name)
    User.create!(email: "calendar_#{SecureRandom.hex(4)}@example.com",
                 password: "password123", display_name: display_name, closing_day: 25)
  end

  def test_西野さんは未設定なら既定メンバー全員が見える
    user = create_user("西野 鷹也")

    assert_equal TeamSchedule::DEFAULT_PERSONS, user.visible_calendar_persons
  ensure
    user&.destroy
  end

  def test_川村さんは未設定なら既定メンバー全員が見える
    user = create_user("川村 卓也")

    assert_equal TeamSchedule::DEFAULT_PERSONS, user.visible_calendar_persons
  ensure
    user&.destroy
  end

  def test_それ以外の人は未設定なら自分の予定だけが見える
    user = create_user("岩切 弘道")

    assert_equal [ "岩切" ], user.visible_calendar_persons
  ensure
    user&.destroy
  end

  def test_既定メンバーに居ない人でも自分の名前で行が出る
    user = create_user("松田 英樹")

    assert_equal [ "松田" ], user.visible_calendar_persons
  ensure
    user&.destroy
  end

  def test_管理者が設定した人物がそのまま見える人になる
    user = create_user("岩切 弘道")
    user.update!(calendar_persons: [ "岩切", "西野" ])

    assert_equal [ "岩切", "西野" ], user.reload.visible_calendar_persons
  ensure
    user&.destroy
  end

  def test_設定を空にすると既定に戻る
    user = create_user("岩切 弘道")
    user.update!(calendar_persons: [ "岩切", "西野" ])
    user.update!(calendar_persons: [])

    assert_equal [ "岩切" ], user.reload.visible_calendar_persons
  ensure
    user&.destroy
  end

  def test_選べる人物には取込済みの人物も含まれる
    schedule = TeamSchedule.create!(date: Date.new(2026, 8, 21), person: "新メンバー",
                                    status: "リモート", year_month: "202608")

    assert_includes TeamSchedule.selectable_persons, "新メンバー"
    assert_includes TeamSchedule.selectable_persons, "西野"
  ensure
    schedule&.destroy
  end
end
