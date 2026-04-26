class AddPositionToPurchaseOrderSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :purchase_order_settings, :position, :integer, default: 0, null: false
    remove_index :purchase_order_settings, name: "index_purchase_order_settings_on_user_id_and_category"
    add_index :purchase_order_settings, [:user_id, :category, :position], unique: true, name: "index_po_settings_on_user_cat_pos"
  end
end
