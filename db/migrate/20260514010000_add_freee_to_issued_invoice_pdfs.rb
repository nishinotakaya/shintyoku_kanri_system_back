class AddFreeeToIssuedInvoicePdfs < ActiveRecord::Migration[8.0]
  def change
    add_column :issued_invoice_pdfs, :freee_deal_id, :string
    add_column :issued_invoice_pdfs, :freee_reported_at, :datetime
  end
end
