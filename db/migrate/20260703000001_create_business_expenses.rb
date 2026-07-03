class CreateBusinessExpenses < ActiveRecord::Migration[8.0]
  # 確定申告用の事業経費（レシート撮影→AI読取→勘定科目分類）。
  # 立替金(expenses=ラボップ請求用)とは完全別管理。
  def change
    create_table :business_expenses do |t|
      t.integer  :user_id, null: false
      t.date     :expense_date
      t.string   :store_name
      t.integer  :amount                              # 税込金額(円)
      t.integer  :tax_rate, default: 10, null: false  # 10 / 8(軽減) / 0
      t.string   :account_category                    # 勘定科目(BusinessExpense::ACCOUNT_CATEGORIES)
      t.string   :memo
      t.integer  :business_ratio, default: 100, null: false # 家事按分(%)
      t.string   :status, default: "needs_review", null: false # needs_review / confirmed
      t.binary   :receipt_data                        # レシート画像
      t.string   :content_type
      t.datetime :ai_extracted_at
      t.integer  :ai_confidence                       # AI分類の確信度(0-100)
      t.text     :ai_raw                              # AI応答(デバッグ用)
      t.timestamps
    end
    add_index :business_expenses, [ :user_id, :expense_date ]
  end
end
