class AddTrelloListNameToBacklogTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_tasks, :trello_list_name, :string
  end
end
