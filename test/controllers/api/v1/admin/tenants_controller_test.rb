require "test_helper"

# Api::V1::Admin::TenantsController: admin だけがテナント(会社)を作成・編集できる。
#
# 注意: このアプリのテストはトランザクションでロールバックされない(test_helper.rb が
# rails/test_help を require していない)ため、name/code はテストごとにランダムな
# サフィックスを付けて一意にし、作成したレコードは teardown で必ず destroy する。
class Api::V1::Admin::TenantsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(email: "tenants_admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @non_admin = User.create!(email: "tenants_nonadmin_#{SecureRandom.hex(4)}@example.com",
                              password: "password123", display_name: "一般 太郎", closing_day: 25)
    @owner_candidate = User.create!(email: "tenants_owner_#{SecureRandom.hex(4)}@example.com",
                                    password: "password123", display_name: "候補 代表", closing_day: 25)
    @member_candidate = User.create!(email: "tenants_member_#{SecureRandom.hex(4)}@example.com",
                                     password: "password123", display_name: "候補 メンバー", closing_day: 25)
    @tenants = []
  end

  def teardown
    @tenants.compact.each(&:destroy)
    [ @admin, @non_admin, @owner_candidate, @member_candidate ].compact.each(&:destroy)
  end

  def create_tenant!(attrs = {})
    suffix = SecureRandom.hex(4)
    tenant = Tenant.create!({ name: "テスト会社-#{suffix}", code: "test-tenant-#{suffix}" }.merge(attrs))
    @tenants << tenant
    tenant
  end

  def test_non_admin_gets_forbidden_on_index
    get "/api/v1/admin/tenants", headers: auth_headers(@non_admin)

    assert_response :forbidden
  end

  def test_admin_can_list_tenants
    tenant = create_tenant!(owner_user: @owner_candidate)

    get "/api/v1/admin/tenants", headers: auth_headers(@admin)

    assert_response :success
    ids = response.parsed_body["tenants"].map { |tenant_json| tenant_json["id"] }
    assert_includes ids, tenant.id
  end

  def test_admin_can_create_tenant_with_owner_and_members
    suffix = SecureRandom.hex(4)

    post "/api/v1/admin/tenants",
      params: {
        name: "新規テナント-#{suffix}",
        code: "new-tenant-#{suffix}",
        owner_user_id: @owner_candidate.id,
        member_user_ids: [ @member_candidate.id ]
      },
      headers: auth_headers(@admin), as: :json

    assert_response :created
    body = response.parsed_body
    @tenants << Tenant.find(body["id"])
    assert_equal "新規テナント-#{suffix}", body["name"]
    assert_equal @owner_candidate.id, body["owner"]["id"]
    assert_equal [ @member_candidate.id ], body["members"].map { |member_json| member_json["id"] }
  end

  def test_non_admin_cannot_create_tenant
    suffix = SecureRandom.hex(4)

    post "/api/v1/admin/tenants",
      params: { name: "拒否テナント-#{suffix}", code: "denied-#{suffix}" },
      headers: auth_headers(@non_admin), as: :json

    assert_response :forbidden
  end

  def test_admin_can_update_tenant_name_and_members
    tenant = create_tenant!(owner_user: @owner_candidate)
    new_name = "更新後テナント-#{SecureRandom.hex(4)}"

    patch "/api/v1/admin/tenants/#{tenant.id}",
      params: { name: new_name, member_user_ids: [ @member_candidate.id ] },
      headers: auth_headers(@admin), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal new_name, body["name"]
    assert_equal [ @member_candidate.id ], body["members"].map { |member_json| member_json["id"] }
  end

  def test_admin_can_remove_member_by_updating_with_empty_list
    tenant = create_tenant!
    tenant.tenant_memberships.create!(user: @member_candidate)

    patch "/api/v1/admin/tenants/#{tenant.id}",
      params: { member_user_ids: [] },
      headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_empty response.parsed_body["members"]
  end

  def test_admin_can_delete_tenant
    tenant = create_tenant!

    delete "/api/v1/admin/tenants/#{tenant.id}", headers: auth_headers(@admin)

    assert_response :no_content
    assert_nil Tenant.find_by(id: tenant.id)
    @tenants.delete(tenant)
  end

  def test_non_admin_cannot_delete_tenant
    tenant = create_tenant!

    delete "/api/v1/admin/tenants/#{tenant.id}", headers: auth_headers(@non_admin)

    assert_response :forbidden
    assert Tenant.exists?(tenant.id)
  end

  private

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end
end
