class AddDoneToTrelloTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :trello_tasks, :done, :boolean, default: false, null: false
  end
end
