class InvoiceSubmission < ApplicationRecord
  # draft = 作成のみ(未申請)。申請(submit)で pending(または admin自分宛は approved)へ。
  STATUSES = %w[draft pending approved rejected].freeze
  KINDS = %w[invoice expense work_report].freeze

  belongs_to :user
  belongs_to :reviewer, class_name: "User", optional: true
  belongs_to :received_purchase_order, optional: true

  serialize :items_override, coder: JSON

  validates :year, presence: true
  validates :month, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }

  scope :draft,    -> { where(status: "draft") }
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
    self.status ||= "draft"
    # submitted_at は「申請した時刻」。draft では nil、申請(submit)時に入れる。
  end
end
