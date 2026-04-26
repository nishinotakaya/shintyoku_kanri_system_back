class AddGoogleTokensToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :google_access_token, :text
    add_column :users, :google_refresh_token, :text
    add_column :users, :google_token_expires_at, :datetime
  end
end
