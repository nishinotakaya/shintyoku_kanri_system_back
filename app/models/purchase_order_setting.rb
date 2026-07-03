class PurchaseOrderSetting < ApplicationRecord
  belongs_to :user
  belongs_to :recipient_user, class_name: "User", optional: true

  serialize :items, coder: JSON, type: Array

  validates :category, presence: true, uniqueness: { scope: [ :user_id, :position ] }
end
