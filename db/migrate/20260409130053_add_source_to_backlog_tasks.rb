class AddSourceToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :source, :string
  end
end
