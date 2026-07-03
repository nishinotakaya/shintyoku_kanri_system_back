class AddHeygenApiKeyToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :heygen_api_key, :string # 個人の HeyGen API キー(未設定なら ENV["HEY_GEN_API_KEY"] を使用)
  end
end
