# 運送(transport)の報酬形態。時給か日給かを選べるようにする。
# 日給の場合は「所定時間」を超えた分を超過時給(残業)で加算する。
class AddPayTypeToInvoiceSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_settings, :pay_type, :string              # hourly(既定) / daily
    add_column :invoice_settings, :daily_rate, :integer           # 日給
    add_column :invoice_settings, :standard_hours, :decimal, precision: 4, scale: 2  # 1日の所定時間
    add_column :invoice_settings, :overtime_unit_price, :integer  # 超過1時間あたりの単価
  end
end
