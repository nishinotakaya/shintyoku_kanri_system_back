class CreateInterviewMindmaps < ActiveRecord::Migration[8.0]
  def change
    create_table :interview_mindmaps do |t|
      t.integer :user_id, null: false        # 対象者(誰の面談対策か)
      t.integer :skill_sheet_id              # 起点のスキルシート(任意)
      t.string  :title
      t.timestamps
    end
    add_index :interview_mindmaps, :user_id
  end
end
