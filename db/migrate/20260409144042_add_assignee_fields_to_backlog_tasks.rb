class AddAssigneeFieldsToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :assignee_name, :string
    add_column :backlog_tasks, :assignee_id, :integer
  end
end
