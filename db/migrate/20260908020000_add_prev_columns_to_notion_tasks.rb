class AddPrevColumnsToNotionTasks < ActiveRecord::Migration[8.0]
  # WBS Excel 書き出し(NotionWbsExcelUpdater)向けの「修正後」列。既存の *_prev(日付/進捗/状態) に揃え、
  # タイトル・担当者・工数もアプリで手編集できるようにする。
  def change
    add_column :notion_tasks, :title_prev, :string
    add_column :notion_tasks, :assignee_name_prev, :string
    add_column :notion_tasks, :workload_prev, :decimal, precision: 6, scale: 2
  end
end
