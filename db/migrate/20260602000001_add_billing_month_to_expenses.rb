class AddBillingMonthToExpenses < ActiveRecord::Migration[8.0]
  def change
    # 立替金が属する請求月 (YYYY-MM)。手動追加時に「表示中の月」を明示するための上書き。
    # nil の場合は従来どおり expense_date と締日(period_for)で月を判定する（交通費の自動生成分など）。
    add_column :expenses, :billing_month, :string
    add_index :expenses, :billing_month
  end
end
