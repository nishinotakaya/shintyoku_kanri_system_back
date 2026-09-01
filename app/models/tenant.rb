# テナント(会社)。代表ユーザー(owner_user)とメンバー(tenant_memberships 経由)で構成される。
class Tenant < ApplicationRecord
  belongs_to :owner_user, class_name: "User", optional: true
  has_many :tenant_memberships, dependent: :destroy
  has_many :member_users, through: :tenant_memberships, source: :user

  CODE_FORMAT = /\A[a-z0-9\-]+\z/

  validates :name, presence: true, uniqueness: true
  validates :code, presence: true, uniqueness: true, format: { with: CODE_FORMAT, message: "は英小文字・数字・ハイフンのみ使用できます" }

  # そのテナントに関わる全ユーザー(代表+メンバー)。代表がメンバーにも登録されていても重複しない。
  def all_users
    User.where(id: [ owner_user_id, *member_users.pluck(:id) ].compact.uniq)
  end
end
