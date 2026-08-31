class CreateContractEvents < ActiveRecord::Migration[8.0]
  def change
    # 追記専用の監査ログ。update/destroy はしない(updated_at を持たせない)。
    create_table :contract_events do |t|
      t.references :contract, null: false, foreign_key: true
      t.string :event, null: false      # created/updated/issued/viewed/signed/voided/duplicated/pdf_viewed
      t.string :actor                   # "user:<id>" or "party_b"
      t.string :ip
      t.string :user_agent
      t.text :detail                    # JSON

      t.datetime :created_at, null: false
    end
  end
end
