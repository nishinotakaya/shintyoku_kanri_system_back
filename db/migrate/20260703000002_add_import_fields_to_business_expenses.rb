class AddImportFieldsToBusinessExpenses < ActiveRecord::Migration[8.0]
  # CSV取込(銀行/カード明細)対応: 取込元の区別と重複取込防止ハッシュを持たせる。
  def change
    add_column :business_expenses, :source, :string, default: "receipt", null: false # receipt / csv
    add_column :business_expenses, :import_hash, :string # sha1(日付|金額|摘要) 重複取込防止
    add_index  :business_expenses, [ :user_id, :import_hash ]
  end
end
