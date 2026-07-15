# TrelloTask (テックリーダーズのカード) 全件を、ユーザーの進捗管理カンバンへ upsert する。
# 保存先は builtin の「テックリーダーズ」ワークスペース(source_type: "trello")。
class TrelloTaskSyncService
  def initialize(user)
    @user = user
  end

  def call
    ProgressWorkspace.ensure_defaults!(@user)
    tech_leaders_workspace_id = @user.progress_workspaces.find_by!(builtin: true, source_type: "trello").id

    synced = 0
    ActiveRecord::Base.transaction do
      TrelloTask.find_each do |trello_task|
        issue_key = "T-#{trello_task.trello_card_id}"

        # 「ゴミ箱」リストのカードは取り込まない。既存の BacklogTask が残っていれば削除して整合を取る。
        if trello_task.list_name.to_s.include?("ゴミ箱")
          @user.backlog_tasks.where(source: "trello", issue_key: issue_key).delete_all
          next
        end

        status = status_for(trello_task.list_name)
        task = @user.backlog_tasks.find_or_initialize_by(
          source: "trello",
          issue_key: issue_key
        )
        task.summary = trello_task.title
        task.memo = trello_task.description
        task.assignee_name = trello_task.assignee_name
        task.start_date = trello_task.start_date
        task.end_date = trello_task.due_date
        task.status_id = status[:id]
        task.status_name = status[:name]
        task.url = trello_task.url
        task.progress_workspace_id = tech_leaders_workspace_id
        task.save!
        synced += 1
      end
    end

    synced
  end

  private

  # リスト名から進捗カンバンのステータスを決める。
  # 作業中/WIP → 処理中、プルリク(レビュー依頼)/検証中 → 処理済、マージ/完了 → 完了、それ以外(タスク優先度/MTG等) → 未対応。
  # 「ドラフトプルリク(WIP_作業中)」は「プルリク」も含むため、作業中系の判定をレビュー系より先に行う。
  def status_for(list_name)
    name = list_name.to_s
    return { id: 2, name: "処理中" } if name.include?("作業中") || name.include?("WIP") || name.include?("進行中") || name.downcase.include?("doing")
    return { id: 3, name: "処理済" } if name.include?("検証") || name.include?("プルリク") || name.include?("レビュー")
    return { id: 4, name: "完了" } if TrelloTask.done_list?(list_name)
    { id: 1, name: "未対応" }
  end
end
