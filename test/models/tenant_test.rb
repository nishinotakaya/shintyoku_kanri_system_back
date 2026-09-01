require "test_helper"

# Tenant: 会社単位のグルーピング。代表(owner_user)とメンバー(tenant_memberships)で構成される。
#
# 注意: このアプリのテストはトランザクションでロールバックされない(test_helper.rb が
# rails/test_help を require していない)ため、name/code はテストごとにランダムな
# サフィックスを付けて一意にし、作成したレコードは teardown で必ず destroy する。
class TenantTest < ActiveSupport::TestCase
  def setup
    @owner = User.create!(email: "tenant_owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "テナント 代表", closing_day: 25)
    @member = User.create!(email: "tenant_member_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "テナント メンバー", closing_day: 25)
    @tenants = []
  end

  def teardown
    @tenants.compact.each(&:destroy)
    [ @owner, @member ].compact.each(&:destroy)
  end

  def build_tenant(attrs = {})
    suffix = SecureRandom.hex(4)
    tenant = Tenant.new({ name: "テスト会社-#{suffix}", code: "test-tenant-#{suffix}" }.merge(attrs))
    @tenants << tenant
    tenant
  end

  def create_tenant!(attrs = {})
    build_tenant(attrs).tap(&:save!)
  end

  def test_name_and_code_are_required
    tenant = Tenant.new

    refute tenant.valid?
    refute_empty tenant.errors[:name]
    refute_empty tenant.errors[:code]
  end

  def test_name_must_be_unique
    existing = create_tenant!
    duplicated = build_tenant(name: existing.name)

    refute duplicated.valid?
    refute_empty duplicated.errors[:name]
  end

  def test_code_must_be_unique
    existing = create_tenant!
    duplicated = build_tenant(code: existing.code)

    refute duplicated.valid?
    refute_empty duplicated.errors[:code]
  end

  def test_code_only_allows_lowercase_letters_numbers_and_hyphens
    tenant = build_tenant(code: "Invalid_Code!")

    refute tenant.valid?
    refute_empty tenant.errors[:code]
  end

  def test_code_allows_lowercase_letters_numbers_and_hyphens
    tenant = build_tenant(code: "abc-123-#{SecureRandom.hex(4)}")

    assert tenant.valid?
  end

  def test_all_users_returns_owner_and_members_without_duplicates
    tenant = create_tenant!(owner_user: @owner)
    tenant.tenant_memberships.create!(user: @member)
    tenant.tenant_memberships.create!(user: @owner) # 代表がメンバーにも入っているケース

    assert_equal [ @owner.id, @member.id ].sort, tenant.all_users.map(&:id).sort
  end

  def test_all_users_without_owner_returns_only_members
    tenant = create_tenant!
    tenant.tenant_memberships.create!(user: @member)

    assert_equal [ @member.id ], tenant.all_users.map(&:id)
  end

  def test_same_user_cannot_be_added_as_member_twice
    tenant = create_tenant!
    tenant.tenant_memberships.create!(user: @member)
    duplicated_membership = tenant.tenant_memberships.build(user: @member)

    refute duplicated_membership.valid?
  end
end
