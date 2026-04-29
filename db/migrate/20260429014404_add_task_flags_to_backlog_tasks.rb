class AddTaskFlagsToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :did_previous, :boolean, default: false, null: false
    add_column :backlog_tasks, :do_today, :boolean, default: false, null: false
  end
end
