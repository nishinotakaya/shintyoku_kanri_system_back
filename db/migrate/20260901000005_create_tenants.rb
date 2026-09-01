class CreateTenants < ActiveRecord::Migration[8.0]
  def change
    create_table :tenants do |t|
      t.string  :name, null: false                # 会社名(例: HAUKUR運送)
      t.string  :code, null: false                 # URLや識別に使う短縮コード(例: haukur)
      t.integer :owner_user_id                     # 代表ユーザー
      t.timestamps
    end
    add_index :tenants, :name, unique: true
    add_index :tenants, :code, unique: true
    add_index :tenants, :owner_user_id
    add_foreign_key :tenants, :users, column: :owner_user_id

    create_table :tenant_memberships do |t|
      t.integer :tenant_id, null: false
      t.integer :user_id, null: false
      t.timestamps
    end
    add_index :tenant_memberships, [ :tenant_id, :user_id ], unique: true
    add_index :tenant_memberships, :user_id
    add_foreign_key :tenant_memberships, :tenants
    add_foreign_key :tenant_memberships, :users
  end
end
