class CreateIssuedInvoicePdfVersions < ActiveRecord::Migration[8.0]
  # 統合 PDF(issued_invoice_pdfs) を再生成/編集で上書きする前に、旧版をここへ退避する。
  # 誤った再生成で請求書が消えても、Fly スナップショットに頼らずアプリから戻せるようにするための安全網。
  def change
    create_table :issued_invoice_pdf_versions do |t|
      t.integer  :issued_invoice_pdf_id, null: false
      t.integer  :user_id
      t.string   :kind
      t.string   :file_format
      t.integer  :year
      t.integer  :month
      t.string   :category
      t.string   :purchase_order_no
      t.text     :source_submission_ids
      t.boolean  :merged
      t.integer  :total_amount
      t.string   :filename
      t.binary   :file_data
      t.string   :note
      t.text     :items_override
      t.datetime :original_generated_at   # 退避元レコードの generated_at
      t.string   :reason                   # 退避理由 (例: overwrite_by_regenerate)
      t.timestamps
    end
    add_index :issued_invoice_pdf_versions, :issued_invoice_pdf_id
  end
end
