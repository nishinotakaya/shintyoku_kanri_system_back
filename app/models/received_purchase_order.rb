class ReceivedPurchaseOrder < ApplicationRecord
  belongs_to :user
  has_many :invoice_submissions, dependent: :nullify

  validates :order_no, presence: true

  scope :for_year_month, ->(year, month) {
    return all if year.blank? || month.blank?
    start_date = Date.new(year.to_i, month.to_i, 1)
    end_date = start_date.end_of_month
    where("(period_start IS NULL AND period_end IS NULL) OR (period_start <= ? AND period_end >= ?)", end_date, start_date)
  }
end
