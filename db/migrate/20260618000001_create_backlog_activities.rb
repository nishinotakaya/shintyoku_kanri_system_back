class CreateBacklogActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :backlog_activities do |t|
      t.references :user, null: false, foreign_key: true
      t.bigint  :activity_id, null: false   # Backlog 側の活動 ID
      t.string  :project_key
      t.string  :issue_key
      t.string  :summary
      t.string  :activity_type              # comment / status / commit / assigner
      t.text    :content                    # コメント本文 / "処理中→処理済み" / コミットメッセージ
      t.date    :occurred_on
      t.string  :month                      # "2026-04"（集計用）
      t.string  :url
      t.timestamps
    end
    add_index :backlog_activities, [ :user_id, :activity_id ], unique: true
    add_index :backlog_activities, [ :user_id, :month ]
    add_index :backlog_activities, :issue_key
  end
end
