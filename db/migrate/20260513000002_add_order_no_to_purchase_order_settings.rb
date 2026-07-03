class AddOrderNoToPurchaseOrderSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :purchase_order_settings, :order_no, :string
  end
end
