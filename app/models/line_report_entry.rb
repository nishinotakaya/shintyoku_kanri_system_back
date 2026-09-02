# LINE で送った進捗報告の1タスク分の記録。
# 送信文面をパースした表示値(「2026/09/10 → 9/15」等)をそのまま持ち、
# 同じ日付×同じタスクは上書きする(idx_line_report_entries_on_user_date_task)。
# Google スプレッドシート(進捗管理表)の月別タブはこのテーブルから全量再生成する。
class LineReportEntry < ApplicationRecord
  belongs_to :user

  validates :reported_on, presence: true
  validates :task_title, presence: true

  scope :in_month, ->(month_start) { where(reported_on: month_start.beginning_of_month..month_start.end_of_month) }
end
