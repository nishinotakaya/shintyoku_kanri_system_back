class AddTaxStatusToUsers < ActiveRecord::Migration[8.0]
  def change
    # 消費税の事業者区分: taxable=課税事業者(インボイス登録・2割特例) / exempt=免税事業者
    add_column :users, :tax_status, :string, null: false, default: "taxable"
  end
end
