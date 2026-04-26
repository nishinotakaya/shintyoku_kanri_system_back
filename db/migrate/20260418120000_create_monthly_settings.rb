class CreateMonthlySettings < ActiveRecord::Migration[8.0]
  def change
    create_table :monthly_settings do |t|
      t.integer :user_id, null: false
      t.integer :year, null: false
      t.integer :month, null: false
      t.date :application_date
      t.timestamps
    end
    add_index :monthly_settings, [:user_id, :year, :month], unique: true
  end
end
