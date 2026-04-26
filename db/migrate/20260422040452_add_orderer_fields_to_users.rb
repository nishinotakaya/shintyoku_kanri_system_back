class AddOrdererFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :can_issue_orders, :boolean, default: false, null: false
    add_column :users, :postal_code, :string
    add_column :users, :address, :string
  end
end
