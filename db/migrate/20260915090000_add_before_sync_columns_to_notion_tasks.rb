class AddBeforeSyncColumnsToNotionTasks < ActiveRecord::Migration[8.0]
  # LINE 進捗報告の「修正前 → 修正後」に使う前回同期値の専用列。
  # これまで *_prev 列に退避していたが、*_prev は WBS 画面で編集した「修正後」の置き場でもあり、
  # Notion 同期のたびに編集内容が前回同期値で上書きされていた(2026-09-15 の 7/7 巻き戻り)。
  def change
    add_column :notion_tasks, :start_date_before_sync, :date
    add_column :notion_tasks, :end_date_before_sync, :date
    add_column :notion_tasks, :progress_rate_before_sync, :decimal, precision: 5, scale: 2
    add_column :notion_tasks, :status_before_sync, :string
  end
end
