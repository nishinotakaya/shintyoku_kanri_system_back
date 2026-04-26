class AddCategoryToInvoiceSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_settings, :category, :string
  end
end
