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
end
