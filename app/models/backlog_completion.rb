class BacklogCompletion < ApplicationRecord
  belongs_to :user
  validates :issue_key, presence: true, uniqueness: { scope: :user_id }
end
