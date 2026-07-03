class AddApplicationDateToIssuedInvoicePdfs < ActiveRecord::Migration[8.0]
  def change
    add_column :issued_invoice_pdfs, :application_date, :date
  end
end
