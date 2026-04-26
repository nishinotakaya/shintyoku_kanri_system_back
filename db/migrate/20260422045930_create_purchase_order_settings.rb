class CreatePurchaseOrderSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :purchase_order_settings do |t|
      t.references :user, null: false, foreign_key: true
      t.string :category
      t.string :subject
      t.string :issuer_company
      t.string :issuer_representative
      t.string :issuer_postal
      t.string :issuer_address
      t.string :recipient_name
      t.string :recipient_postal
      t.string :recipient_address
      t.date :period_start
      t.date :period_end
      t.integer :closing_day
      t.integer :hours_per_cycle
      t.integer :rate_per_hour
      t.integer :base_monthly
      t.string :delivery_location
      t.string :payment_method

      t.timestamps
    end
    add_index :purchase_order_settings, [:user_id, :category], unique: true
  end
end
