class RemoveClientAddressOverrideFromInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    # 宛先住所機能は不採用のためカラムを削除（請求書に宛先住所は載せない方針）。
    remove_column :invoice_submissions, :client_address_override, :text
  end
end
