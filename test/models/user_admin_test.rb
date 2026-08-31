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
end
