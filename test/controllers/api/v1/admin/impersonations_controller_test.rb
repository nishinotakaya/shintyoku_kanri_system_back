require "test_helper"

# なりすましログイン: 管理者だけが他ユーザーの JWT を発行してもらえる。
# 発行されたトークンは、そのユーザー本人としてそのまま使える。
#
# 注意: このアプリのテストはトランザクションでロールバックされないため、
# email はランダムサフィックスで一意にし、teardown で必ず destroy する。
class Api::V1::Admin::ImpersonationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(email: "imp_admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @target = User.create!(email: "imp_target_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "運送外注 太郎", closing_day: 31)
    @non_admin = User.create!(email: "imp_nonadmin_#{SecureRandom.hex(4)}@example.com",
                              password: "password123", display_name: "一般 次郎", closing_day: 25)
  end

  def teardown
    [ @admin, @target, @non_admin ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_admin_gets_token_that_authenticates_as_the_target_user
    post "/api/v1/admin/impersonations", params: { user_id: @target.id },
         headers: auth_headers(@admin), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @target.id, body.dig("user", "id")
    assert_equal @admin.display_name, body.dig("admin", "display_name")

    # 受け取ったトークンで /me を叩くと、なりすまし先本人として認証される
    get "/api/v1/me", headers: { "Authorization" => "Bearer #{body['token']}" }

    assert_response :success
    assert_equal @target.id, JSON.parse(response.body)["id"]
  end

  def test_non_admin_cannot_impersonate
    post "/api/v1/admin/impersonations", params: { user_id: @target.id },
         headers: auth_headers(@non_admin), as: :json

    assert_response :forbidden
  end

  def test_cannot_impersonate_self
    post "/api/v1/admin/impersonations", params: { user_id: @admin.id },
         headers: auth_headers(@admin), as: :json

    assert_response :unprocessable_entity
  end

  def test_unknown_user_returns_not_found
    post "/api/v1/admin/impersonations", params: { user_id: 0 },
         headers: auth_headers(@admin), as: :json

    assert_response :not_found
  end

  def test_requires_authentication
    post "/api/v1/admin/impersonations", params: { user_id: @target.id }, as: :json

    assert_response :unauthorized
  end

  # --- ここから: 「詰まない」ための挙動 ---

  # なりすましトークンには戻り先が埋まっているので、/me がそれを返す。
  # フロントはこれを見てバナーを出すため、localStorage が消えても管理者に戻れる。
  def test_me_exposes_impersonator_so_the_banner_survives_cleared_storage
    get "/api/v1/me", headers: impersonation_headers_for(@target)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @admin.id, body.dig("impersonator", "id")
    assert_equal @admin.display_name, body.dig("impersonator", "display_name")
  end

  # 通常ログインでは impersonator は入らない(バナーを誤表示しない)
  def test_me_has_no_impersonator_on_normal_login
    get "/api/v1/me", headers: auth_headers(@target)

    assert_response :success
    assert_nil JSON.parse(response.body)["impersonator"]
  end

  # なりすましトークンだけを根拠に管理者へ戻れる = 帰り道がサーバ側にある
  def test_delete_returns_admin_token_without_any_client_state
    delete "/api/v1/admin/impersonations", headers: impersonation_headers_for(@target)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @admin.id, body.dig("user", "id")

    get "/api/v1/me", headers: { "Authorization" => "Bearer #{body['token']}" }

    assert_response :success
    assert_equal @admin.id, JSON.parse(response.body)["id"]
  end

  def test_delete_is_rejected_when_not_impersonating
    delete "/api/v1/admin/impersonations", headers: auth_headers(@admin)

    assert_response :unprocessable_entity
  end

  # 管理者に戻らずに別ユーザーへ直接乗り換えられる(管理者権限はトークンが保持している)
  def test_can_switch_to_another_user_while_impersonating
    post "/api/v1/admin/impersonations", params: { user_id: @non_admin.id },
         headers: impersonation_headers_for(@target), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @non_admin.id, body.dig("user", "id")
    assert_equal @admin.display_name, body.dig("admin", "display_name")

    # 乗り換え後も戻り先は元の管理者のまま
    get "/api/v1/me", headers: { "Authorization" => "Bearer #{body['token']}" }

    assert_equal @admin.id, JSON.parse(response.body).dig("impersonator", "id")
  end

  # 非管理者のトークンで乗り換えようとしても通らない(なりすまし中でも権限判定は発行元の管理者)
  def test_non_admin_cannot_switch_even_with_an_impersonation_token
    non_admin_token = @target.issue_jwt(impersonated_by: @non_admin)

    post "/api/v1/admin/impersonations", params: { user_id: @admin.id },
         headers: { "Authorization" => "Bearer #{non_admin_token}" }, as: :json

    assert_response :forbidden
  end

  # linked_user_id を持つアカウント(wing西野 → admin西野)になりすましても、
  # BaseController の linked 解決に横取りされず本人のままでいられる
  def test_impersonating_a_linked_account_stays_on_that_account
    @linked = User.create!(email: "imp_linked_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "wing 太郎",
                           closing_day: 25, linked_user: @admin)

    get "/api/v1/me", headers: impersonation_headers_for(@linked)

    assert_response :success
    assert_equal @linked.id, JSON.parse(response.body)["id"]
  ensure
    @linked&.destroy
  end

  # --- サブ管理者(テナント代表) ---

  def test_sub_admin_can_impersonate_their_tenant_member
    suffix = SecureRandom.hex(4)
    sub_owner = User.create!(email: "imp_sub_#{suffix}@example.com", password: "password123",
                             display_name: "西野 雄太郎", closing_day: 31)
    tenant = Tenant.create!(name: "なりすまし運送_#{suffix}", code: "imp-#{suffix}", owner_user: sub_owner)
    tenant.tenant_memberships.create!(user: @target)

    post "/api/v1/admin/impersonations", params: { user_id: @target.id },
         headers: auth_headers(sub_owner), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @target.id, body.dig("user", "id")

    get "/api/v1/me", headers: { "Authorization" => "Bearer #{body['token']}" }
    assert_response :success
    assert_equal @target.id, JSON.parse(response.body)["id"]
  ensure
    tenant&.destroy
    sub_owner&.destroy
  end

  def test_sub_admin_cannot_impersonate_users_outside_their_scope
    suffix = SecureRandom.hex(4)
    sub_owner = User.create!(email: "imp_sub2_#{suffix}@example.com", password: "password123",
                             display_name: "西野 雄太郎", closing_day: 31)
    tenant = Tenant.create!(name: "なりすまし運送2_#{suffix}", code: "imp2-#{suffix}", owner_user: sub_owner)

    post "/api/v1/admin/impersonations", params: { user_id: @non_admin.id },
         headers: auth_headers(sub_owner), as: :json

    assert_response :forbidden
  ensure
    tenant&.destroy
    sub_owner&.destroy
  end

  def test_sub_admin_index_lists_only_manageable_users
    suffix = SecureRandom.hex(4)
    sub_owner = User.create!(email: "imp_sub3_#{suffix}@example.com", password: "password123",
                             display_name: "西野 雄太郎", closing_day: 31)
    tenant = Tenant.create!(name: "なりすまし運送3_#{suffix}", code: "imp3-#{suffix}", owner_user: sub_owner)
    tenant.tenant_memberships.create!(user: @target)

    get "/api/v1/admin/impersonations", headers: auth_headers(sub_owner)

    assert_response :success
    ids = JSON.parse(response.body).map { |row| row["id"] }
    assert_includes ids, @target.id
    refute_includes ids, @non_admin.id
    refute_includes ids, sub_owner.id
  ensure
    tenant&.destroy
    sub_owner&.destroy
  end

  private

  def impersonation_headers_for(user, impersonated_by: nil)
    { "Authorization" => "Bearer #{user.issue_jwt(impersonated_by: impersonated_by || @admin)}" }
  end
end
