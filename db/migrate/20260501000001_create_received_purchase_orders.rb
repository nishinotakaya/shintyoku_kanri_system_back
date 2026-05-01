class CreateReceivedPurchaseOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :received_purchase_orders do |t|
      t.references :user, null: false                   # 受注者 (西野 or 川村)
      t.string :order_no, null: false                   # 例: ORD-010014
      t.string :customer_name                           # タマホーム / タマリビング
      t.string :category                                # wings / living etc
      t.string :subject                                 # 案件名
      t.date :period_start
      t.date :period_end
      t.integer :total_amount                           # 発注金額(税込)
      t.text :note                                      # 「※シェアラウンジ回数券（押上5回分）支給」等
      t.string :file_url                                # 発注書 PDF の URL (Google Drive etc)
      t.timestamps
    end
    add_index :received_purchase_orders, :order_no
  end
end
