class AddDefaultTransitToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :default_transit_from, :string
    add_column :users, :default_transit_to, :string
    add_column :users, :default_transit_fee, :integer
    add_column :users, :default_transit_line, :string
  end
end
