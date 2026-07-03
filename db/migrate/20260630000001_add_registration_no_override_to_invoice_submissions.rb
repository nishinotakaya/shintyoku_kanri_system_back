class AddRegistrationNoOverrideToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    # インボイス番号(適格請求書発行事業者登録番号)の請求書単体での上書き。
    # nil なら従来通りユーザーの invoice_setting.registration_no を使う。
    add_column :invoice_submissions, :registration_no_override, :string
  end
end
