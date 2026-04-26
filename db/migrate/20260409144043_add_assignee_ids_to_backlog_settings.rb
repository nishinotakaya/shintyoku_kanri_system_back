class AddAssigneeIdsToBacklogSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_settings, :assignee_ids, :text
  end
end
