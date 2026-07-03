class AddPaidAtToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_submissions, :paid_at, :datetime
    add_index :invoice_submissions, :paid_at
  end
end
