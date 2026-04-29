class CreatePurchaseOrderHistories < ActiveRecord::Migration[8.0]
  def change
    create_table :purchase_order_histories do |t|
      t.references :user, null: false, foreign_key: true
      t.string :category
      t.integer :position
      t.string :order_no
      t.string :subject
      t.string :recipient_name
      t.date :period_start
      t.date :period_end
      t.integer :total_amount
      t.text :payload
      t.datetime :issued_at

      t.timestamps
    end
  end
end
