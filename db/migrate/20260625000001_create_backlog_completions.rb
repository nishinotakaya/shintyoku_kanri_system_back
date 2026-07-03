class CreateBacklogCompletions < ActiveRecord::Migration[8.0]
  # 課題の「完了日」を Backlog の changeLog(状態→完了) から取得して保存する。
  # アクティビティフィードに残らない古い完了も拾えるよう、同期時に課題単位で保持する。
  def change
    create_table :backlog_completions do |t|
      t.integer  :user_id, null: false
      t.string   :issue_key, null: false
      t.date     :completed_on
      t.datetime :synced_at
      t.timestamps
    end
    add_index :backlog_completions, [ :user_id, :issue_key ], unique: true, name: "index_backlog_completions_on_user_issue"
  end
end
