class AddMemoToNotionTasks < ActiveRecord::Migration[8.0]
  # リビング(Notion)タスクにも、タマ(Backlog)タスクと同じ手入力メモを持たせる。
  # Notion 由来の項目ではないので NotionSyncService の再同期では上書きされない。
  def change
    add_column :notion_tasks, :memo, :text
  end
end
