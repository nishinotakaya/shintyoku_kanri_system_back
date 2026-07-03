class AddBankInfoOverrideToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  # 請求書ごとに振込先(お振込先)を上書きできるようにする。
  # 空なら従来どおり invoice_settings.bank_info(設定の既定値)を使う。
  def change
    add_column :invoice_submissions, :bank_info_override, :string
  end
end
