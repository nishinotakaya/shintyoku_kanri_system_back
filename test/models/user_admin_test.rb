require "test_helper"

# 管理者判定。以前は表示名に苗字「西野」を含むだけで管理者にしていたため、
# 同姓の一般ユーザー(西野 雄太郎)を追加した時点で全データが見える管理者になる穴があった。
# 「西野 鷹也」本人 か ADMIN_EMAILS のときだけ管理者にすることを固定する。
class UserAdminTest < Minitest::Test
  def build(display_name:, email: "admin_test_#{SecureRandom.hex(4)}@example.com")
    User.new(email: email, password: "password123", display_name: display_name)
  end

  def test_full_name_nishino_takaya_is_admin
    assert build(display_name: "西野 鷹也").admin?
    assert build(display_name: "wing西野 鷹也").admin?, "wing アカウントの表記も本人扱い"
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
