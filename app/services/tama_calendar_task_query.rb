# カレンダー「当日のタスク」タマタブに表示する BacklogTask を返すクエリ。
# - リビング(source=notion)やスキルシート(source=sheet)を混ぜないよう、
#   Backlog系(backlog / 手入力local / 旧nil)のみに絞る。リビングは /notion_tasks を使う
# - source だけではテックリーダーズ/プライベート等の進捗カンバンで手作成した
#   local タスクが混入するため、Wing(backlog連携)ワークスペース + 旧データ(workspace未割当) にも絞る
# - 対象日に進行中のタスクに加え、完了(status_id=4)は完了後3日間だけ表示する
class TamaCalendarTaskQuery
  SOURCES = %w[backlog local].freeze
  RECENT_COMPLETED_DAYS = 3
  # 表示順: 処理済(3) → 処理中(2) → 未対応(1) → 完了(4) → その他
  STATUS_ORDER = Arel.sql("CASE status_id WHEN 3 THEN 1 WHEN 2 THEN 2 WHEN 1 THEN 3 WHEN 4 THEN 4 ELSE 5 END").freeze

  def initialize(user:, date:, assignee: nil)
    @user = user
    @date = date
    @assignee = assignee
  end

  def call
    scope = @user.backlog_tasks
      .where("source IS NULL OR source IN (?)", SOURCES)
      .where(progress_workspace_id: wing_workspace_ids + [ nil ])
      .where(
        "(status_id <> 4 AND ((start_date IS NULL OR start_date <= ?) AND (end_date IS NULL OR end_date >= ?) OR " \
        "(created_on IS NULL OR created_on <= ?) AND (completed_on IS NULL OR completed_on >= ?))) " \
        "OR (status_id = 4 AND completed_on IS NOT NULL AND completed_on >= ? AND completed_on <= ?)",
        @date, @date, @date, @date,
        @date - RECENT_COMPLETED_DAYS, @date
      )
    scope = scope.where("assignee_name LIKE ?", "%#{@assignee}%") if @assignee.present?
    scope.order(STATUS_ORDER, Arel.sql("COALESCE(position, 9999)"), :issue_key)
  end

  private

  def wing_workspace_ids
    @user.progress_workspaces.where(source_type: "backlog").pluck(:id)
  end
end
