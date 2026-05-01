class AddCompanyBurdenToExpenses < ActiveRecord::Migration[8.0]
  def change
    # 会社負担対象か (#4: 川村の押上5回分のみ true 等)
    # デフォルト true (既存データは全て会社負担扱い)
    add_column :expenses, :company_burden, :boolean, default: true, null: false
  end
end
