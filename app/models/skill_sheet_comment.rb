class SkillSheetComment < ApplicationRecord
  belongs_to :skill_sheet

  validates :body, presence: true

  def as_payload
    {
      id: id,
      target: target,
      body: body,
      author_name: author_name,
      author_user_id: author_user_id,
      created_at: created_at&.iso8601
    }
  end
end
