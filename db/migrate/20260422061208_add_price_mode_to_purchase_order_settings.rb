class AddPriceModeToPurchaseOrderSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :purchase_order_settings, :price_mode, :string
    add_column :purchase_order_settings, :range_min, :integer
    add_column :purchase_order_settings, :range_max, :integer
  end
end
