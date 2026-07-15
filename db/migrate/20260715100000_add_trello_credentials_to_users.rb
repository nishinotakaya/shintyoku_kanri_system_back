class AddTrelloCredentialsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :trello_api_key, :string   # 個人の Trello API キー(未設定なら ENV["TRELLO_API_KEY"] を使用)
    add_column :users, :trello_api_token, :string  # 個人の Trello API トークン(未設定なら ENV["TRELLO_API_TOKEN"] を使用)
    add_column :users, :trello_board_id, :string   # 個人の Trello ボード ID(未設定なら ENV["TRELLO_BOARD_ID"] を使用)
  end
end
