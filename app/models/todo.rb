class Todo < ApplicationRecord
  belongs_to :user

  validates :title, presence: true

  scope :active, -> { where(completed: [false, nil]).order(:priority, :due_date, :created_at) }
  scope :completed_list, -> { where(completed: true).order(updated_at: :desc) }
end
