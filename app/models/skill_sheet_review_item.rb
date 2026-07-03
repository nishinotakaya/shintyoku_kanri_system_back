# AI 添削(または手動)の「指摘」を 1 件 = 1 行で保持する。CRUD 対象。
class SkillSheetReviewItem < ApplicationRecord
  belongs_to :skill_sheet

  SOURCES = %w[ai manual].freeze
  validates :source, inclusion: { in: SOURCES }

  def as_payload
    {
      id: id,
      target: target,
      field: field,
      issues: issues,
      suggestion: suggestion,
      applied: applied,
      source: source,
      position: position
    }
  end
end
