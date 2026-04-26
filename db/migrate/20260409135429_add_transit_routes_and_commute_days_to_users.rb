class AddTransitRoutesAndCommuteDaysToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :transit_routes, :text
    add_column :users, :commute_days, :text
  end
end
