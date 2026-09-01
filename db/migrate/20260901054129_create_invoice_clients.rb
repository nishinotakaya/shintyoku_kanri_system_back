# 請求先(宛先)マスタ。1ユーザーが複数の取引先に請求書を出す運用
# (運送: 取引先 → 西野 雄太郎 → ドライバー) のために、宛先を登録して選べるようにする。
class CreateInvoiceClients < ActiveRecord::Migration[8.0]
  def change
    create_table :invoice_clients do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false          # 会社名・氏名
      t.string :honorific, default: "御中"  # 御中 / 様
      t.string :subject                    # 既定の件名(請求書ごとに上書き可)
      t.string :postal_code
      t.string :address
      t.string :tel
      t.string :fax
      t.string :contact_name               # 担当者
      t.text :note
      t.boolean :is_default, default: false, null: false
      t.integer :position, default: 0, null: false
      t.datetime :archived_at              # 削除は物理削除せずアーカイブ(過去の請求書が参照するため)
      t.timestamps
    end
    add_index :invoice_clients, [ :user_id, :archived_at ]
  end
end
