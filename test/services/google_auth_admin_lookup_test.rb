require "test_helper"

# AC-03: google_refresh_token が暗号化されると SQL の where.not 比較は使えない。
# 暗号化後 / 未移行の平文行のどちらでも、トークン保持 admin を Ruby 側 present? 判定で見つけること。
class GoogleAuthAdminLookupTest < Minitest::Test
  ADMIN_EMAIL = User::ADMIN_EMAILS.first

  def setup
    @created_users = []
    User.where(email: User::ADMIN_EMAILS).destroy_all
    @admin = create_user(ADMIN_EMAIL)
    @operator = create_user("op_#{SecureRandom.hex(4)}@example.com")
  end

  def teardown
    @created_users.each { |user| User.where(id: user.id).destroy_all }
  end

  def create_user(email)
    user = User.create!(email: email, password: "password123", display_name: "lookup #{email}")
    @created_users << user
    user
  end

  def write_plaintext(user, column, value)
    quoted = User.connection.quote(value)
    User.connection.execute("UPDATE users SET #{column} = #{quoted} WHERE id = #{user.id}")
  end

  def test_credential_user_finds_admin_with_encrypted_refresh_token
    @admin.update!(google_refresh_token: "refresh-enc")

    assert_equal @admin.id, GoogleAuth.credential_user(@operator).id
  end

  def test_credential_user_finds_admin_with_legacy_plaintext_refresh_token
    write_plaintext(@admin, :google_refresh_token, "refresh-legacy")

    assert_equal @admin.id, GoogleAuth.credential_user(@operator).id
  end

  def test_credential_user_falls_back_to_admin_access_token_only
    @admin.update!(google_access_token: "access-enc")

    assert_equal @admin.id, GoogleAuth.credential_user(@operator).id
  end

  def test_credential_user_ignores_blank_and_nil_tokens
    @admin.update!(google_refresh_token: "", google_access_token: nil)

    assert_equal @operator.id, GoogleAuth.credential_user(@operator).id
  end

  def test_credential_user_ignores_non_admin_token_holder
    other = create_user("other_#{SecureRandom.hex(4)}@example.com")
    other.update!(google_refresh_token: "refresh-other")

    assert_equal @operator.id, GoogleAuth.credential_user(@operator).id
  end

  def test_writer_user_prefers_admin_with_encrypted_refresh_token
    @admin.update!(google_refresh_token: "refresh-enc")
    @operator.update!(google_refresh_token: "refresh-op")

    assert_equal @admin.id, GoogleAuth.writer_user(@operator).id
  end

  def test_writer_user_finds_admin_with_legacy_plaintext_refresh_token
    write_plaintext(@admin, :google_refresh_token, "refresh-legacy")
    @operator.update!(google_refresh_token: "refresh-op")

    assert_equal @admin.id, GoogleAuth.writer_user(@operator).id
  end

  def test_stored_refresh_token_is_not_plaintext_in_db
    @admin.update!(google_refresh_token: "refresh-enc")
    raw = User.connection.select_value("SELECT google_refresh_token FROM users WHERE id = #{@admin.id}")

    refute_includes raw.to_s, "refresh-enc"
  end
end
