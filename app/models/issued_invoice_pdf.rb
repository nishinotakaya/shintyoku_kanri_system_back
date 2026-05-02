class IssuedInvoicePdf < ApplicationRecord
  belongs_to :user

  serialize :source_submission_ids, coder: JSON

  validates :kind, presence: true
  validates :filename, presence: true
end
