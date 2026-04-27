class PurchaseOrderSetting < ApplicationRecord
  belongs_to :user

  serialize :items, coder: JSON, type: Array

  validates :category, presence: true, uniqueness: { scope: [ :user_id, :position ] }
end
