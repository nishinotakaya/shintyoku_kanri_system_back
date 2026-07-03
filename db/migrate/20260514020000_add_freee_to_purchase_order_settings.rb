class AddFreeeToPurchaseOrderSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :purchase_order_settings, :freee_deal_id, :string
    add_column :purchase_order_settings, :freee_reported_at, :datetime
  end
end
