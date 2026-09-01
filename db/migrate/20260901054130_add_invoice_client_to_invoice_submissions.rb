# 請求書ごとの宛先。invoice_client_id は「どのマスタを選んだか」、
# client_name_override / client_honorific_override は発行時点のスナップショット。
# マスタを後から編集しても、既に選んだ請求書の宛先は変わらない。
class AddInvoiceClientToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    add_reference :invoice_submissions, :invoice_client, foreign_key: true, null: true
    add_column :invoice_submissions, :client_name_override, :string
    add_column :invoice_submissions, :client_honorific_override, :string
  end
end
