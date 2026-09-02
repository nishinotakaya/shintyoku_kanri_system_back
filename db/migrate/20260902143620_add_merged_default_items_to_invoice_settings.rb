# 統合請求書(ラボップ宛)だけに載せる固定明細。
# default_items は「支払側(本人への請求書)」の行なので、そこにシェアラウンジ控除を入れると
# 本人への支払額まで減ってしまう。請求側の控除はこの列に分ける(merged_unit_price と同じ二層構造)。
class AddMergedDefaultItemsToInvoiceSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_settings, :merged_default_items, :text
  end
end
