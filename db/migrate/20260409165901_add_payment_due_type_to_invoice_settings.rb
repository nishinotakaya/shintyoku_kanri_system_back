class AddPaymentDueTypeToInvoiceSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_settings, :payment_due_type, :string
  end
end
