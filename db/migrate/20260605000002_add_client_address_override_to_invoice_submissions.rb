class AddClientAddressOverrideToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    # 請求書ごとに宛先(相手の会社)の住所を記入できるようにする。
    # 空なら宛名の下に住所を出さない。
    add_column :invoice_submissions, :client_address_override, :text
  end
end
