class AddPdfDataToReceivedPurchaseOrders < ActiveRecord::Migration[8.0]
  def change
    add_column :received_purchase_orders, :file_data, :binary
    add_column :received_purchase_orders, :filename, :string
    add_column :received_purchase_orders, :content_type, :string
    add_column :received_purchase_orders, :ai_extracted_at, :datetime
    add_column :received_purchase_orders, :ai_raw_text, :text
  end
end
