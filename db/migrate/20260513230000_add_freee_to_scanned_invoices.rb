class AddFreeeToScannedInvoices < ActiveRecord::Migration[8.0]
  def change
    add_column :scanned_invoices, :freee_deal_id, :string
    add_column :scanned_invoices, :freee_reported_at, :datetime
  end
end
