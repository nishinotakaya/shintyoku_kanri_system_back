# freee 連携口座(銀行/カード)の入出金明細。freee の wallet_txn をこのシステムの DB に同期する台帳。
# 経費(business_expenses)とは別管理。registered=false のものが「未登録」= まだ取引化していない明細。
class BankTransaction < ApplicationRecord
  belongs_to :user
  belongs_to :business_expense, optional: true

  scope :unregistered, -> { where(registered: false) }
  scope :expense_side, -> { where(entry_side: "expense") }

  def payment_label
    case payment_method
    when "credit_card" then "カード"
    when "bank" then "口座"
    else payment_method
    end
  end
end
