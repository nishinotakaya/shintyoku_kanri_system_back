# 税込(内税)/税抜(外税)の切替。既定は従来どおり税抜(明細合計に消費税を加算)。
# 運送(雄太郎)のように「日給・超過時給が税込価格」の人だけ true にする。
class AddTaxIncludedToInvoiceSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_settings, :tax_included, :boolean, default: false, null: false
  end
end
