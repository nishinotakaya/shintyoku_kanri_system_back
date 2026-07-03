class CreateScannedInvoices < ActiveRecord::Migration[8.0]
  def change
    create_table :scanned_invoices do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :original_filename
      t.string  :partner_name       # 取引先（例: "株式会社ラボップ"）
      t.string  :subject            # 件名
      t.integer :subtotal_amount    # 税抜小計
      t.integer :tax_amount         # 消費税
      t.integer :total_amount       # 税込合計
      t.date    :issue_date         # 発行日
      t.date    :due_date           # 支払期限
      t.string  :invoice_number     # 請求書番号
      t.text    :raw_text           # PDF から抽出した生テキスト
      t.json    :raw_ai_response    # AI 出力の生 JSON
      t.string  :status, default: "pending"  # pending / confirmed / rejected
      t.timestamps
    end
  end
end
