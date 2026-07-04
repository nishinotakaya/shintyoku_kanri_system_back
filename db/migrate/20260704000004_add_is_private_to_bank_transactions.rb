class AddIsPrivateToBankTransactions < ActiveRecord::Migration[8.0]
  def change
    # is_private: プライベート(私的支出)印。true にすると未登録一覧から外れ、経費計上の対象にしない。
    add_column :bank_transactions, :is_private, :boolean, default: false, null: false
  end
end
