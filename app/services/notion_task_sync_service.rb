# NotionTask (リビングの WBS タスク) 全件を、ユーザーの進捗管理カンバンへ upsert する。
# 保存先は builtin の「リビング」ワークスペース(source_type: "notion")。
class NotionTaskSyncService
  # Notion 側のステータス文言 → BacklogTask のステータス ID/ラベル
  STATUS_MAP = {
    "完了" => { id: 4, name: "完了" },
    "進行中" => { id: 2, name: "処理中" }
  }.freeze
  DEFAULT_STATUS = { id: 1, name: "未対応" }.freeze

  def initialize(user)
    @user = user
  end

  def call
    ProgressWorkspace.ensure_defaults!(@user)
    living_workspace_id = @user.progress_workspaces.find_by!(builtin: true, source_type: "notion").id

    synced = 0
    ActiveRecord::Base.transaction do
      NotionTask.find_each do |notion_task|
        status = STATUS_MAP[notion_task.status.to_s] || DEFAULT_STATUS
        task = @user.backlog_tasks.find_or_initialize_by(
          source: "notion",
          issue_key: "N-#{notion_task.notion_block_id.first(8)}"
        )
        task.summary = notion_task.title
        task.memo = notion_task.note
        task.assignee_name = notion_task.assignee_name
        task.start_date = notion_task.start_date
        task.end_date = notion_task.end_date
        task.progress_value = notion_task.progress_rate&.to_f
        task.status_id = status[:id]
        task.status_name = status[:name]
        task.progress_workspace_id = living_workspace_id
        task.save!
        synced += 1
      end
    end

    synced
  end
end
