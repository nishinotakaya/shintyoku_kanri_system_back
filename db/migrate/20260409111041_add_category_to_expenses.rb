class AddCategoryToExpenses < ActiveRecord::Migration[8.0]
  def change
    add_column :expenses, :category, :string
  end
end
