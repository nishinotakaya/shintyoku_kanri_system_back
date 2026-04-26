class AddItemsAndRemarksToPurchaseOrderSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :purchase_order_settings, :items, :text
    add_column :purchase_order_settings, :remarks, :text
  end
end
