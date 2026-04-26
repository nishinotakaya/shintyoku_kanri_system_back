class AddPositionToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :position, :integer
  end
end
