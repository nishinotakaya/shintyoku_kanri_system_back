class EncryptGithubPat < ActiveRecord::Migration[8.0]
  # PAT は repo スコープでコードの読み書き権限そのもの。freee_connection と同じく
  # ActiveRecord Encryption で暗号化保存する。暗号文は元より長いので text 化する。
  def up
    change_column :github_settings, :personal_access_token, :text
  end

  def down
    change_column :github_settings, :personal_access_token, :string
  end
end
