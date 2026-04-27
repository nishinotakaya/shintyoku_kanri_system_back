class MonthlySetting < ApplicationRecord
  belongs_to :user

  validates :year, :month, presence: true
  validates :user_id, uniqueness: { scope: [ :year, :month ] }

  def self.find_or_initialize_for(user, year, month)
    find_or_initialize_by(user_id: user.id, year: year, month: month)
  end
end
