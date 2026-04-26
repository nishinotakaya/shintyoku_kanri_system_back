class CreateBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :backlog_tasks do |t|
      t.references :user, null: false, foreign_key: true
      t.string :issue_key
      t.string :summary
      t.integer :status_id
      t.string :status_name
      t.date :created_on
      t.date :completed_on
      t.date :due_date

      t.timestamps
    end
  end
end
