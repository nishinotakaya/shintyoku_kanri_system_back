class AddDueDateOverrideToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    # 請求書ごとに支払期限を上書きできるようにする。
    # 未設定(nil)なら従来どおり請求設定(payment_due_type/days)から計算する。
    add_column :invoice_submissions, :due_date_override, :date
  end
end
