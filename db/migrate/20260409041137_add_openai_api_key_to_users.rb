class AddOpenaiApiKeyToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :openai_api_key, :string
  end
end
