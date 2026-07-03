class ScannedInvoice < ApplicationRecord
  belongs_to :user

  scope :pending,   -> { where(status: "pending") }
  scope :confirmed, -> { where(status: "confirmed") }

  # freee 売上計上に流し込めるか
  def freee_ready?
    total_amount.present? && due_date.present?
  end
end
