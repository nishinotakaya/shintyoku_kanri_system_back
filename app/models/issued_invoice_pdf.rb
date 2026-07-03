class IssuedInvoicePdf < ApplicationRecord
  belongs_to :user
  has_many :versions, -> { order(created_at: :desc) },
           class_name: "IssuedInvoicePdfVersion", dependent: :destroy

  serialize :source_submission_ids, coder: JSON
  serialize :items_override, coder: JSON

  validates :kind, presence: true
  validates :filename, presence: true
end
