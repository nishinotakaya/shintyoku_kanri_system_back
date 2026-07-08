class GithubSetting < ApplicationRecord
  belongs_to :user

  # Personal Access Token は repo スコープでコード読み書き権限そのもの。
  # freee_connection と同様に ActiveRecord Encryption で暗号化保存する。
  encrypts :personal_access_token
end
