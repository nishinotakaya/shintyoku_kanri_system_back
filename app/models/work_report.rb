class WorkReport < ApplicationRecord
  belongs_to :user

  CATEGORIES = %w[wings living techleaders resystems].freeze

  validates :work_date, presence: true, uniqueness: { scope: [:user_id, :category] }

  scope :in_range, ->(range) { where(work_date: range).order(:work_date) }
  scope :by_category, ->(cat) { where(category: cat) }
end
