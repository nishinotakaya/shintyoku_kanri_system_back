# Backlog 同期で開始日/期限日が変わったとき、変更前の値を残して「修正前 → 修正後」を出せるようにする。
# Notion(notion_tasks)と同じ *_prev 方式に揃える。
class AddPrevDatesToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :start_date_prev, :date
    add_column :backlog_tasks, :end_date_prev, :date
  end
end
