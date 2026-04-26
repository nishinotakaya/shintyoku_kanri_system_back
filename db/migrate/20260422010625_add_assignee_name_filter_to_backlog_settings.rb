class AddAssigneeNameFilterToBacklogSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_settings, :assignee_name_filter, :string
  end
end
