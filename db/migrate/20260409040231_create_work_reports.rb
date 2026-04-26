class CreateWorkReports < ActiveRecord::Migration[8.0]
  def change
    create_table :work_reports do |t|
      t.references :user, null: false, foreign_key: true
      t.date :work_date, null: false
      t.string :content
      t.decimal :hours, precision: 4, scale: 2
      t.time :clock_in
      t.time :clock_out
      t.integer :break_minutes, default: 0
      t.string :transit_section
      t.integer :transit_fee

      t.timestamps
    end
    add_index :work_reports, [:user_id, :work_date], unique: true
  end
end
