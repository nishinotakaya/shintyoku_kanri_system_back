class AddOverridesToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_submissions, :total_override, :integer
    add_column :invoice_submissions, :item_label_override, :string
    add_column :invoice_submissions, :subject_override, :string
  end
end
