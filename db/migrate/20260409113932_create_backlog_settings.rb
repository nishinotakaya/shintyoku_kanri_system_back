class CreateBacklogSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :backlog_settings do |t|
      t.references :user, null: false, foreign_key: true
      t.string :backlog_url
      t.string :backlog_email
      t.string :backlog_password
      t.integer :board_id
      t.integer :user_backlog_id
      t.text :session_cookie

      t.timestamps
    end
  end
end
