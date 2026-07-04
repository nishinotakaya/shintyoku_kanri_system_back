class AddPaymentSourceToBusinessExpenses < ActiveRecord::Migration[8.0]
  def change
    # freee 連携で取り込んだ経費の支払元(口座/カード)を記録する。
    # payment_source: 口座名(例: しんきんVISAカード) / payment_method: cash|credit_card|bank
    add_column :business_expenses, :payment_source, :string
    add_column :business_expenses, :payment_method, :string
  end
end
