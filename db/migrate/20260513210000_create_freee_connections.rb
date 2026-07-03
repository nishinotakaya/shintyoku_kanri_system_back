class CreateFreeeConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :freee_connections do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string   :company_id          # freee の cu_cid（例: "3304727"）
      t.string   :company_name
      t.text     :session_cookie      # 内部 API 用（暗号化）
      t.string   :csrf_token          # 内部 API 用
      t.string   :identity            # 接続時のメールアドレス（再ログイン用）
      t.text     :password_encrypted  # 暗号化パスワード（cookie 期限切れ時の自動再接続用）
      t.datetime :last_connected_at
      t.integer  :last_status_code
      t.string   :status, default: "disconnected"  # connected / disconnected / error
      t.text     :last_error
      t.timestamps
    end
  end
end
