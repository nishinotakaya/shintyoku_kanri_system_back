class CreateBacklogSummaryNotes < ActiveRecord::Migration[8.0]
  def change
    create_table :backlog_summary_notes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :month, null: false       # "2026-04"（サマリの行キー）
      t.string :issue_key, null: false    # "SAP-3947"（サマリの行キー）
      t.text   :note                      # 備考（上司報告用の手入力）
      t.string :status_override           # 状態推移の手入力上書き（空なら活動から自動算出）
      t.timestamps
    end
    add_index :backlog_summary_notes, [ :user_id, :month, :issue_key ], unique: true,
              name: "index_backlog_summary_notes_on_user_month_issue"
  end
end
