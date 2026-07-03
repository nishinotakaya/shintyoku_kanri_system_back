class AddNotionBlockIdToBacklogSummaryNotes < ActiveRecord::Migration[8.0]
  # 上司報告サマリの各行(月×課題)に、対応する Notion(WBS) タスクを手動で紐付けるためのカラム。
  # Backlog 課題キーと Notion の WBS タスクは自動対応しないため、画面のセレクトボックスで選んだ
  # NotionTask#notion_block_id を保存し、予定(開始/完了)などを上司報告に取り込む。
  def change
    add_column :backlog_summary_notes, :notion_block_id, :string
  end
end
