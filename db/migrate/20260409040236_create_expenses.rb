class CreateExpenses < ActiveRecord::Migration[8.0]
  def change
    create_table :expenses do |t|
      t.references :user, null: false, foreign_key: true
      t.date :expense_date
      t.string :purpose
      t.string :transport_type
      t.string :from_station
      t.string :to_station
      t.boolean :round_trip
      t.string :receipt_no
      t.integer :amount
      t.string :payee_or_line

      t.timestamps
    end
  end
end
