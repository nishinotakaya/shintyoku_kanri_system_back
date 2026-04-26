class BacklogTask < ApplicationRecord
  belongs_to :user

  STATUS_PROGRESS = { 1 => 0.0, 2 => 0.4, 3 => 0.8, 4 => 1.0 }.freeze
  STATUS_NAMES = { 1 => "未対応", 2 => "処理中", 3 => "処理済", 4 => "完了" }.freeze

  scope :by_status, ->(ids) { where(status_id: ids) }
  scope :active, -> { where.not(status_id: 4) }

  # progress_value が手動設定されていればそれを、なければステータスから自動算出
  def progress
    progress_value || STATUS_PROGRESS[status_id] || 0.0
  end
end
