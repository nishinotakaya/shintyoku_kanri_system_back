class AddFreeeToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_submissions, :freee_deal_id, :string
    add_column :invoice_submissions, :freee_reported_at, :datetime
  end
end
