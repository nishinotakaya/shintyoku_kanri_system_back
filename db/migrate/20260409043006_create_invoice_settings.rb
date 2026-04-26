class CreateInvoiceSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :invoice_settings do |t|
      t.references :user, null: false, foreign_key: true
      t.string :client_name
      t.string :subject
      t.string :item_label
      t.integer :unit_price
      t.integer :tax_rate
      t.integer :payment_due_days
      t.string :issuer_name
      t.string :registration_no
      t.string :postal_code
      t.string :address
      t.string :tel
      t.string :email
      t.string :bank_info
      t.text :default_items

      t.timestamps
    end
  end
end
