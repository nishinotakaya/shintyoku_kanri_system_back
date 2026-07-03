class CreateNotionTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :notion_tasks do |t|
      t.string  :notion_block_id, null: false
      t.string  :wbs_level
      t.string  :title, null: false
      t.string  :parent_task
      t.string  :assignee_name
      t.string  :assignee_notion_id
      t.date    :start_date
      t.date    :end_date
      t.decimal :workload, precision: 6, scale: 2
      t.decimal :progress_rate, precision: 5, scale: 2
      t.string  :status
      t.string  :priority
      t.text    :note
      t.datetime :synced_at, null: false

      t.timestamps
    end

    add_index :notion_tasks, :notion_block_id, unique: true
    add_index :notion_tasks, [ :start_date, :end_date ]
    add_index :notion_tasks, :assignee_name
  end
end
