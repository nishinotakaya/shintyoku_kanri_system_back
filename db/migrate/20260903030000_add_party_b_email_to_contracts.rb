class AddPartyBEmailToContracts < ActiveRecord::Migration[8.0]
  def change
    add_column :contracts, :party_b_email, :string
  end
end
