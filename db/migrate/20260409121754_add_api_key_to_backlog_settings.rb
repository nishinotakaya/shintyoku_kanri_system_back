class AddApiKeyToBacklogSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :backlog_settings, :api_key, :string
  end
end
