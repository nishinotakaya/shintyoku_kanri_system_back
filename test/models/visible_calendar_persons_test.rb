require "test_helper"

# カレンダーに予定行を出す人物は、管理者が /users で設定できる。
# 未設定のときの既定は「テナント(会社)に紐づく人はそのテナントの中だけ、
# 西野さん・川村さんは全員分、それ以外は自分の予定だけ」。
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

  # 同姓の別ユーザー(西野 鷹也さん / 西野 雄太郎さん)が、同じ「西野」の行に相乗りしないこと。
  # 人物行の持ち主は先に登録されたユーザーで、後から入った人はフルネームの行になる。
  def test_同姓のユーザーは他人の人物行を借りない
    takaya = create_user("西野 鷹也")
    yutaro = create_user("西野 雄太郎")

    assert_equal "西野", takaya.own_calendar_person
    assert_equal "西野 雄太郎", yutaro.own_calendar_person
    assert_equal [ "西野 雄太郎" ], yutaro.visible_calendar_persons
  ensure
    yutaro&.destroy
    takaya&.destroy
  end

  # 苗字が「西野」でも、全員分のカレンダーを見るのは西野 鷹也さんだけ。
  def test_同姓のユーザーは全員分のカレンダーを見ない
    takaya = create_user("西野 鷹也")
    yutaro = create_user("西野 雄太郎")

    assert takaya.sees_whole_team_calendar?
    assert_not yutaro.sees_whole_team_calendar?
  ensure
    yutaro&.destroy
    takaya&.destroy
  end

  # テナント(会社)の代表は、自分と配下メンバーだけが見える。メンバー未登録なら自分1人。
  def test_テナント代表は自分と配下メンバーだけが見える
    owner = create_user("運送 代表")
    tenant = Tenant.create!(name: "テスト運送_#{SecureRandom.hex(4)}", code: "t-#{SecureRandom.hex(4)}", owner_user: owner)

    assert_equal [ "運送" ], owner.visible_calendar_persons

    member = create_user("配下 太郎")
    tenant.tenant_memberships.create!(user: member)

    assert_equal [ "運送", "配下" ], owner.reload.visible_calendar_persons
    # メンバー側からは代表の予定は見えない(見えるのは自分だけ)
    assert_equal [ "配下" ], member.reload.visible_calendar_persons
  ensure
    tenant&.destroy
    member&.destroy
    owner&.destroy
  end

  # 管理者が明示設定した人物行は、テナント既定より優先される。
  def test_テナントに紐づいていても設定が優先される
    owner = create_user("運送 代表")
    tenant = Tenant.create!(name: "テスト運送_#{SecureRandom.hex(4)}", code: "t-#{SecureRandom.hex(4)}", owner_user: owner)
    owner.update!(calendar_persons: [ "西野", "川村" ])

    assert_equal [ "西野", "川村" ], owner.reload.visible_calendar_persons
  ensure
    tenant&.destroy
    owner&.destroy
  end

  # 見えていても操作できるのは自分の行だけ(表記ゆれ「川村卓也」は本人だけ許容)。
  def test_操作できるのは自分の人物行だけ
    kawamura = create_user("川村 卓也")
    takaya = create_user("西野 鷹也")
    yutaro = create_user("西野 雄太郎")
    kawamura.update!(calendar_persons: [ "西野", "川村", "大隅" ])

    assert_equal [ "川村" ], kawamura.reload.editable_calendar_persons
    assert kawamura.can_edit_calendar_person?("川村卓也")
    assert_not kawamura.can_edit_calendar_person?("西野")
    assert_not yutaro.can_edit_calendar_person?("西野")
    assert yutaro.can_edit_calendar_person?("西野 雄太郎")
  ensure
    yutaro&.destroy
    takaya&.destroy
    kawamura&.destroy
  end
end
