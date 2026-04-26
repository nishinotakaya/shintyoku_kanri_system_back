class AddDeployFieldsToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :deploy_date, :date
    add_column :backlog_tasks, :deploy_note, :string
  end
end
