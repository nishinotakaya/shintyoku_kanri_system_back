class AddUrlToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :url, :string
  end
end
