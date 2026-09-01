class TenantMembership < ApplicationRecord
  belongs_to :tenant
  belongs_to :user

  validates :user_id, uniqueness: { scope: :tenant_id }
end
