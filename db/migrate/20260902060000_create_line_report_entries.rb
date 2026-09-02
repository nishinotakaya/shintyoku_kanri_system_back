class CreateLineReportEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :line_report_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.date :reported_on, null: false
      t.string :task_title, null: false
      t.string :start_date_text
      t.string :end_date_text
      t.string :progress_text
      t.string :status_text
      t.text :note
      t.string :url
      t.timestamps
    end
    # 同じ日付×同じタスクの報告は上書き(アップデート)する
    add_index :line_report_entries, [ :user_id, :reported_on, :task_title ],
              unique: true, name: "idx_line_report_entries_on_user_date_task"
  end
end
