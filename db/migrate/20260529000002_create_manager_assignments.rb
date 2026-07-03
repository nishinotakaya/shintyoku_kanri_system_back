class CreateManagerAssignments < ActiveRecord::Migration[8.0]
  def change
    # サブ管理者(manager) が管理できる対象(managee) を表す割当。
    # 例: 加藤(manager) → 岩切(managee)。川村は割り当てないので管理対象外。
    create_table :manager_assignments do |t|
      t.integer :manager_id, null: false
      t.integer :managee_id, null: false
      t.timestamps
    end
    add_index :manager_assignments, [ :manager_id, :managee_id ], unique: true
    add_index :manager_assignments, :managee_id
  end
end
