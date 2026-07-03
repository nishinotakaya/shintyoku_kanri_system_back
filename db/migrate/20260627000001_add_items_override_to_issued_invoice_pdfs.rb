class AddItemsOverrideToIssuedInvoicePdfs < ActiveRecord::Migration[8.0]
  # 統合請求書の編集明細を、元申請(invoice_submissions)を書き換えずに
  # 統合PDF自身に保持するためのカラム。
  def change
    add_column :issued_invoice_pdfs, :items_override, :text
  end
end
