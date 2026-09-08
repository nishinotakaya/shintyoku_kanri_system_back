class AddWbsSubmittedOverridesToNotionTasks < ActiveRecord::Migration[8.0]
  # 提出済(wbs_mark_submitted)にした *_prev(修正後)値のスナップショット。
  # ここに記録された値と現在の *_prev が一致する項目は「提出済」=赤塗りしない。
  def change
    add_column :notion_tasks, :wbs_submitted_overrides, :json, null: false, default: {}
  end
end
