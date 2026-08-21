class CreateUserDataSourcePermissions < ActiveRecord::Migration[8.0]
  def change
    create_table :user_data_source_permissions do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :source_type, null: false                      # backlog / notion / trello
      t.boolean :can_view,  null: false, default: false
      t.boolean :can_sync,  null: false, default: false
      t.boolean :can_write, null: false, default: false        # 外部サービス側への書き込み
      t.integer :credential_owner_id                           # API キーを借りる相手(nil = 自分のキー)
      t.timestamps
    end

    add_index :user_data_source_permissions, [ :user_id, :source_type ], unique: true,
              name: "index_data_source_permissions_on_user_and_source"
    add_foreign_key :user_data_source_permissions, :users, column: :credential_owner_id
  end
end
