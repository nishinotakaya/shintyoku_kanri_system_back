class AddExcelExcludedToExpenses < ActiveRecord::Migration[8.0]
  def change
    add_column :expenses, :excel_excluded, :boolean, default: false, null: false
  end
end
