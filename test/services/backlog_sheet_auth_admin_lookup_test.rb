require "test_helper"
require "ostruct"

# AC-03: BacklogSheetAuth#authorized_sheets_service は admin 候補を where.not(SQL) で探していた。
# 暗号化後も refresh_token 保持 admin が候補になり、空/nil/非 admin は候補にならないこと。
# 外部 API は呼ばず、GoogleAuth.build に渡された候補ユーザーを記録して検証する。
class BacklogSheetAuthAdminLookupTest < Minitest::Test
  include BacklogSheetAuth

  def setup
    @created_users = []
    User.where(email: User::ADMIN_EMAILS).destroy_all
    @admin = create_user(User::ADMIN_EMAILS.first)
    @operator = create_user("op_#{SecureRandom.hex(4)}@example.com")
    @built_for = []
  end

  def teardown
    @created_users.each { |user| User.where(id: user.id).destroy_all }
  end

  def create_user(email)
    user = User.create!(email: email, password: "password123", display_name: "bsa #{email}")
    @created_users << user
    user
  end

  # build 呼び出しで候補を記録して失敗させる(総当たりは全滅 → raise)。
  def candidates_tried
    recorder = @built_for
    original = GoogleAuth.method(:build)
    GoogleAuth.define_singleton_method(:build) { |user| recorder << user.id; raise "stop" }
    begin
      authorized_sheets_service("sheet_id", @operator)
    rescue RuntimeError
      nil
    ensure
      GoogleAuth.define_singleton_method(:build, original)
    end
    @built_for
  end

  def test_encrypted_refresh_token_admin_is_a_candidate
    @admin.update!(google_refresh_token: "refresh-enc")

    assert_includes candidates_tried, @admin.id
  end

  def test_legacy_plaintext_refresh_token_admin_is_a_candidate
    quoted = User.connection.quote("refresh-legacy")
    User.connection.execute("UPDATE users SET google_refresh_token = #{quoted} WHERE id = #{@admin.id}")

    assert_includes candidates_tried, @admin.id
  end

  def test_blank_refresh_token_admin_is_not_a_candidate
    @admin.update!(google_refresh_token: "")

    refute_includes candidates_tried, @admin.id
  end

  def test_non_admin_with_refresh_token_is_not_a_candidate_unless_operator
    other = create_user("other_#{SecureRandom.hex(4)}@example.com")
    other.update!(google_refresh_token: "refresh-other")

    refute_includes candidates_tried, other.id
  end
end
