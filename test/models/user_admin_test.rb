require "test_helper"

# 管理者判定。以前は表示名に苗字「西野」を含むだけで管理者にしていたため、
# 同姓の一般ユーザー(西野 雄太郎)を追加した時点で全データが見える管理者になる穴があった。
# その後、表示名が「西野 鷹也」と完全一致する場合も管理者扱いしていたが、表示名は
# 公開サインアップや PATCH /api/v1/me で本人が自由に変更できるため、誰でも表示名を
# 「西野 鷹也」に変えるだけで管理者になれる権限昇格の穴になっていた。
# 現在は ADMIN_EMAILS に含まれる email かどうかだけで管理者を判定する。
class UserAdminTest < Minitest::Test
  def build(display_name:, email: "admin_test_#{SecureRandom.hex(4)}@example.com")
    User.new(email: email, password: "password123", display_name: display_name, closing_day: 25)
  end

  # 表示名が「西野 鷹也」でも、email が ADMIN_EMAILS に無ければ管理者にしない
  def test_display_name_alone_does_not_grant_admin
    refute build(display_name: "西野 鷹也").admin?
    refute build(display_name: "wing西野 鷹也").admin?
  end

  def test_admin_email_is_admin_regardless_of_name
    User::ADMIN_EMAILS.each do |email|
      assert build(display_name: "別名", email: email).admin?, email
    end
  end

  # 同じ苗字でも別人は管理者にしない
  def test_same_surname_other_person_is_not_admin
    refute build(display_name: "西野 雄太郎").admin?
    refute build(display_name: "西野雄太郎").admin?
    refute build(display_name: "西野").admin?
  end

  def test_unrelated_user_is_not_admin
    refute build(display_name: "川村 卓也").admin?
  end

  # 一般ユーザーが表示名を「西野 鷹也」に更新して管理者になりすますことはできない
  def test_general_user_cannot_impersonate_admin_display_name
    user = build(display_name: "山田 太郎")
    user.display_name = "西野 鷹也"
    refute user.valid?
    assert_includes user.errors[:display_name], "この表示名は使用できません"
  end

  # ADMIN_EMAILS のユーザーは自分の本名として「西野 鷹也」を名乗れる
  def test_admin_user_can_use_own_name_as_display_name
    admin_user = build(display_name: "西野 鷹也", email: User::ADMIN_EMAILS.first)
    assert admin_user.valid?
  end

  # 通知宛先・請求書宛名に使う主管理者は、同姓の別人が先に登録されていても西野 鷹也本人
  def test_primary_admin_prefers_takaya_over_same_surname_user
    created = []
    created << User.create!(email: "yutaro_#{SecureRandom.hex(4)}@example.com", password: "password123",
                            display_name: "西野 雄太郎", closing_day: 25)
    takaya = User.find_by(email: User::ADMIN_EMAILS.first) ||
      User.create!(email: User::ADMIN_EMAILS.first, password: "password123",
                   display_name: "西野 鷹也", closing_day: 25).tap { |user| created << user }
    assert_equal takaya.id, User.primary_admin&.id
  ensure
    created&.each(&:destroy)
  end
end
