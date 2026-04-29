class InvoiceSubmission < ApplicationRecord
  STATUSES = %w[pending approved rejected].freeze
  KINDS = %w[invoice expense].freeze

  belongs_to :user
  belongs_to :reviewer, class_name: "User", optional: true

  serialize :items_override, coder: JSON

  validates :year, presence: true
  validates :month, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }

  scope :pending,  -> { where(status: "pending") }
  scope :approved, -> { where(status: "approved") }
  scope :invoices, -> { where(kind: "invoice") }
  scope :expenses, -> { where(kind: "expense") }

  before_validation :set_defaults

  def pending?
    status == "pending"
  end

  def approved?
    status == "approved"
  end

  def year_month
    format("%04d%02d", year, month)
  end

  private

  def set_defaults
    self.status ||= "pending"
    self.submitted_at ||= Time.current
  end
end
