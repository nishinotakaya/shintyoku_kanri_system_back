class AddPdfDataToScannedInvoices < ActiveRecord::Migration[8.0]
  def change
    add_column :scanned_invoices, :pdf_data, :text  # base64 encoded PDF
    add_column :scanned_invoices, :content_type, :string  # 'application/pdf' 等
  end
end
