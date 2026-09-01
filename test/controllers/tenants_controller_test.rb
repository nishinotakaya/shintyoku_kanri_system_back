require "test_helper"

# 会社(テナント)名は設定画面から変えられる。変更できるのは代表本人と admin だけ。
class TenantsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = User.create!(email: "tenant_owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "運送 代表", closing_day: 31)
    @member = User.create!(email: "tenant_member_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "配下 太郎", closing_day: 31)
    @outsider = User.create!(email: "outsider_#{SecureRandom.hex(4)}@example.com",
                             password: "password123", display_name: "無関係 花子", closing_day: 25)
    @tenant = Tenant.create!(name: "テスト運送_#{SecureRandom.hex(4)}", code: "t-#{SecureRandom.hex(4)}", owner_user: @owner)
    @tenant.tenant_memberships.create!(user: @member)
  end

  def teardown
    @tenant&.destroy
    [ @owner, @member, @outsider ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_owner_can_rename_own_tenant
    patch "/api/v1/tenants/#{@tenant.id}", params: { name: "HAUKUR運送" },
          headers: auth_headers(@owner), as: :json

    assert_response :success
    assert_equal "HAUKUR運送", @tenant.reload.name
  end

  def test_member_cannot_rename_tenant
    patch "/api/v1/tenants/#{@tenant.id}", params: { name: "勝手に改名" },
          headers: auth_headers(@member), as: :json

    assert_response :forbidden
    assert_not_equal "勝手に改名", @tenant.reload.name
  end

  # 会社に関わっていない人には一覧にも出ない
  def test_index_returns_only_own_tenants
    get "/api/v1/tenants", headers: auth_headers(@member)
    assert_response :success
    assert_equal [ @tenant.id ], JSON.parse(response.body)["tenants"].map { |tenant| tenant["id"] }

    get "/api/v1/tenants", headers: auth_headers(@outsider)
    assert_response :success
    assert_empty JSON.parse(response.body)["tenants"]
  end

  # カレンダーの見出しに出す会社名。代表・メンバーのどちらでも自分の会社が出る
  def test_tenant_name
    assert_equal @tenant.name, @owner.reload.tenant_name
    assert_equal @tenant.name, @member.reload.tenant_name
    assert_nil @outsider.reload.tenant_name
  end
end
