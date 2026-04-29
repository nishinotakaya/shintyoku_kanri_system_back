class AddSubmissionExtras < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_submissions, :kind, :string, default: "invoice", null: false
    add_column :invoice_submissions, :items_override, :text
    add_column :invoice_submissions, :application_date_override, :date
    add_index  :invoice_submissions, :kind
  end
end
