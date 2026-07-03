class AddPurchaseOrderNoOverrideToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_submissions, :purchase_order_no_override, :string
  end
end
