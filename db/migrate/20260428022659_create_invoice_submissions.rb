class CreateInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    create_table :invoice_submissions do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :year
      t.integer :month
      t.string :category
      t.string :status
      t.datetime :submitted_at
      t.datetime :reviewed_at
      t.integer :reviewer_id
      t.text :note

      t.timestamps
    end
  end
end
