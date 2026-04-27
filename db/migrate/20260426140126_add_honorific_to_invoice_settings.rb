class AddHonorificToInvoiceSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_settings, :honorific, :string
  end
end
