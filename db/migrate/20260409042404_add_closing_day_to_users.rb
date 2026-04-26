class AddClosingDayToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :closing_day, :integer, default: 25, null: false
  end
end
