# WBS 画面から手動追加したタスク(Notion 由来ではない行)を区別する。
# NotionSyncService は manual: false の行だけを削除対象にする。
class AddManualToNotionTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :notion_tasks, :manual, :boolean, default: false, null: false
  end
end
