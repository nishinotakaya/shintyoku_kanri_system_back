class AddFieldsToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :start_date, :date
    add_column :backlog_tasks, :end_date, :date
    add_column :backlog_tasks, :memo, :text
  end
end
