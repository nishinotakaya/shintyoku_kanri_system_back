class AddInvoiceRegisteredToUsers < ActiveRecord::Migration[8.0]
  # 適格請求書発行事業者(インボイス登録=課税事業者)かどうか。
  # 消費税の仕入税額控除の計算に使う: 登録済み=100%控除 / 免税事業者=経過措置80%(〜2026/9)。
  def change
    add_column :users, :invoice_registered, :boolean, default: false, null: false
  end
end
