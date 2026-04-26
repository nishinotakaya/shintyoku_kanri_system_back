class AddCustomOffDaysToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :custom_off_days, :text
  end
end
