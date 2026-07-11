class AddFreeeDealIdToBusinessExpenses < ActiveRecord::Migration[8.0]
  def change
    # freee 一括連携で作成した取引(deal)の id。連携済みレコードの追跡・重複連携防止に使う。
    add_column :business_expenses, :freee_deal_id, :integer
  end
end
