class Expense < ApplicationRecord
  belongs_to :user

  TRANSPORT_TYPES = %w[train bus taxi shinkansen flight].freeze
  CATEGORIES = %w[wings living].freeze

  validates :expense_date, :amount, presence: true

  scope :in_range, ->(range) { where(expense_date: range).order(:expense_date, :id) }
  scope :by_category, ->(cat) { where(category: cat) }
end
