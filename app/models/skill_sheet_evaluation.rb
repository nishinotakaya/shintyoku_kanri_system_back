class SkillSheetEvaluation < ApplicationRecord
  belongs_to :skill_sheet, inverse_of: :evaluations

  LEVELS = %w[A B C D E].freeze

  validates :label, presence: true
  validates :level, inclusion: { in: LEVELS }

  def as_payload
    { id: id, label: label, level: level }
  end
end
