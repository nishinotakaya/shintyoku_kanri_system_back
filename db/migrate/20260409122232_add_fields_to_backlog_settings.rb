class AddFieldsToBacklogSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_settings, :memo, :text
  end
end
