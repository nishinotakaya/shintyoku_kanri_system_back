class CreateIssuedInvoicePdfs < ActiveRecord::Migration[8.0]
  def change
    create_table :issued_invoice_pdfs do |t|
      t.references :user, null: false                          # 発行者 (admin/西野)
      t.string :kind, null: false                              # invoice / expense
      t.string :file_format, null: false, default: "pdf"       # pdf / xlsx
      t.integer :year
      t.integer :month
      t.string :category
      t.string :purchase_order_no
      t.text :source_submission_ids                            # JSON: [5, 8, 13] 等
      t.boolean :merged, null: false, default: false
      t.integer :total_amount                                  # 税込合計
      t.string :filename, null: false
      t.binary :file_data, null: false                         # PDF/XLSX のバイナリ
      t.string :note
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :issued_invoice_pdfs, %i[year month category]
    add_index :issued_invoice_pdfs, :purchase_order_no
  end
end
