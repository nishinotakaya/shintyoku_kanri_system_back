class CreateBankTransactions < ActiveRecord::Migration[8.0]
  def change
    # freee 連携口座(銀行/カード)の入出金明細をこのシステムの DB で管理する台帳。
    # business_expenses とは別（振替・引落・私的支出が混ざるため経費集計に混ぜない）。
    # registered=true になった明細だけ business_expense 化して経費計上する。
    create_table :bank_transactions do |t|
      t.integer :user_id, null: false
      t.bigint  :freee_wallet_txn_id, null: false   # freee wallet_txn の id（同期キー）
      t.integer :walletable_id                        # freee 口座 id
      t.string  :walletable_name                      # 口座/カード名
      t.string  :payment_method                       # bank | credit_card
      t.date    :txn_date
      t.integer :amount, default: 0, null: false      # 出金額(get_spent_amount)
      t.string  :entry_side                           # expense | income
      t.string  :description                          # 摘要(店名・振込先)
      t.string  :suggested_account_item               # freee 推奨科目
      t.integer :suggested_tax_code
      t.string  :status_str                           # freee 側の状態(unreconciled 等)
      t.boolean :registered, default: false, null: false # 取引登録済みか(未登録=false)
      t.integer :business_expense_id                  # こっちで登録した場合のリンク
      t.datetime :synced_at
      t.timestamps
    end
    add_index :bank_transactions, [ :user_id, :freee_wallet_txn_id ], unique: true, name: "idx_bank_txns_user_wallet_txn"
    add_index :bank_transactions, [ :user_id, :registered ]
  end
end
