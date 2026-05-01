class AddReceivedPurchaseOrderToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    add_reference :invoice_submissions, :received_purchase_order, null: true, foreign_key: false
  end
end
