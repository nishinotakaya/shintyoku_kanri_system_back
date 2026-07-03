class NotionTask < ApplicationRecord
  validates :notion_block_id, presence: true, uniqueness: true
  validates :title, presence: true

  scope :for_date, ->(date) {
    where("start_date IS NULL OR start_date <= ?", date)
      .where("end_date IS NULL OR end_date >= ?", date)
  }

  scope :for_assignee, ->(name) { where(assignee_name: name) if name.present? }

  # 未着手 + 進行中（完了以外）。未設定 (NULL/空) も active 扱い
  scope :active, -> { where("status IS NULL OR status = '' OR status != ?", "完了") }
end
