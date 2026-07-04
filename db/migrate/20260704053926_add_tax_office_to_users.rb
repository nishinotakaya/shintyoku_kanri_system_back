class AddTaxOfficeToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :tax_office, :string
    # 既存運用: 西野(admin)の所轄は松戸税務署
    execute <<~SQL
      UPDATE users SET tax_office = '松戸' WHERE display_name LIKE '%西野%'
    SQL
  end

  def down
    remove_column :users, :tax_office
  end
end
