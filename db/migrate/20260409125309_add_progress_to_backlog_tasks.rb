class AddProgressToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :progress_value, :float
  end
end
