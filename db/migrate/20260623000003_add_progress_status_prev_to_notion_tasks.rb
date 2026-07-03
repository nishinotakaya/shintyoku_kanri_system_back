class AddProgressStatusPrevToNotionTasks < ActiveRecord::Migration[8.0]
  # 進捗率/進捗状況の「修正前(前回同期値)」を保持する。開始日/終了日の *_prev と同じ仕組み。
  def change
    add_column :notion_tasks, :progress_rate_prev, :decimal, precision: 5, scale: 2
    add_column :notion_tasks, :status_prev, :string
  end
end
