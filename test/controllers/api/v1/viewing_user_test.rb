require "test_helper"

# BaseController#viewing_user / MeController#pickable_users:
# 「他ユーザーとして閲覧」(as_user_id) できる範囲は manageable_user_ids に一本化されている。
# admin=全員 / サブ管理者(テナント代表)=管理対象+自分 / 一般ユーザー=自分のみ。
class Api::V1::ViewingUserTest < ActionDispatch::IntegrationTest
  def setup
    suffix = SecureRandom.hex(4)
    @owner = User.create!(email: "viewing_owner_#{suffix}@example.com", password: "password123",
                          display_name: "西野 雄太郎", closing_day: 31, work_categories: [ "transport" ])
    @driver = User.create!(email: "viewing_driver_#{suffix}@example.com", password: "password123",
                           display_name: "運送外注 太郎", closing_day: 31)
    @stranger = User.create!(email: "viewing_stranger_#{suffix}@example.com", password: "password123",
                             display_name: "他人 花子", closing_day: 25)
    @tenant = Tenant.create!(name: "テスト運送_#{suffix}", code: "t-#{suffix}", owner_user: @owner)
    @tenant.tenant_memberships.create!(user: @driver)
    @driver.work_reports.create!(work_date: Date.new(2026, 9, 10), category: "transport")
    @stranger.work_reports.create!(work_date: Date.new(2026, 9, 10), category: "wings")
  end

  def teardown
    @tenant&.destroy
    [ @owner, @driver, @stranger ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_tenant_owner_is_a_sub_admin_and_manages_members
    assert @owner.sub_admin?
    assert_equal [ @owner.id, @driver.id ].sort, @owner.manageable_user_ids.sort
    refute @driver.sub_admin?
  end

  def test_pickable_users_for_tenant_owner_are_self_and_members
    get "/api/v1/users/pickable", headers: auth_headers(@owner)

    assert_response :success
    assert_equal [ @owner.id, @driver.id ], response.parsed_body.map { |u| u["id"] }
  end

  def test_pickable_users_is_empty_for_plain_users
    get "/api/v1/users/pickable", headers: auth_headers(@driver)

    assert_response :success
    assert_equal [], response.parsed_body
  end

  def test_tenant_owner_views_a_member_via_as_user_id
    get "/api/v1/work_reports", params: { month: "2026-09", as_user_id: @driver.id }, headers: auth_headers(@owner)

    assert_response :success
    assert_equal @driver.id, response.parsed_body.dig("viewing", "id")
    assert_equal [ "2026-09-10" ], response.parsed_body["reports"].map { |r| r["work_date"] }
  end

  def test_as_user_id_outside_the_managed_scope_falls_back_to_self
    get "/api/v1/work_reports", params: { month: "2026-09", as_user_id: @stranger.id }, headers: auth_headers(@owner)

    assert_response :success
    assert_equal @owner.id, response.parsed_body.dig("viewing", "id")
    assert_empty response.parsed_body["reports"]
  end

  def test_plain_member_cannot_view_anyone_else
    get "/api/v1/expenses", params: { month: "2026-09", as_user_id: @owner.id }, headers: auth_headers(@driver)

    assert_response :success
    get "/api/v1/work_reports", params: { month: "2026-09", as_user_id: @stranger.id }, headers: auth_headers(@driver)
    assert_equal @driver.id, response.parsed_body.dig("viewing", "id")
  end
end
