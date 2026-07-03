class AddPrevDatesToNotionTasks < ActiveRecord::Migration[8.0]
  # 開始日/終了日の「修正前(前回同期値)」を保持する。
  # Notion 同期で日付が変わったとき、変更前の値を *_prev に退避し、現在値(修正後)と並べて見られるようにする。
  def change
    add_column :notion_tasks, :start_date_prev, :date
    add_column :notion_tasks, :end_date_prev, :date
  end
end
