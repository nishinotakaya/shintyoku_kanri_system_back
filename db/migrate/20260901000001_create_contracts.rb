class CreateContracts < ActiveRecord::Migration[8.0]
  def change
    create_table :contracts do |t|
      t.references :user, null: false, foreign_key: true # 甲(発行者)
      t.string :title, null: false, default: "業務委託契約書"
      t.string :party_a_name
      t.text   :party_a_address
      t.string :party_a_representative
      t.string :party_b_name
      t.text   :party_b_address
      t.string :party_b_representative
      t.date   :contract_date
      t.date   :start_on
      t.date   :end_on
      t.text   :articles                 # JSON配列 [{"heading","body"}]
      t.text   :special_terms
      t.string :status, null: false, default: "draft" # draft / sent / signed / void
      t.string :share_token_digest       # 生トークンは保存しない(SHA256 hex)
      t.datetime :share_expires_at
      t.datetime :sent_at
      t.datetime :signed_at
      t.string :signer_name
      t.text   :signature_image          # PNG data URI(検証済み)
      t.string :signer_ip
      t.string :signer_user_agent
      t.string :content_sha256           # 署名時に凍結した内容のハッシュ
      t.binary :signed_pdf

      t.timestamps
    end

    add_index :contracts, :share_token_digest, unique: true
  end
end
