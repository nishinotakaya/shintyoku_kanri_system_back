class BacklogSetting < ApplicationRecord
  belongs_to :user

  # 外部サービスの認証情報は暗号化して保存する。
  encrypts :backlog_password, :api_key, :session_cookie

  DEFAULTS = {
    backlog_url: ENV.fetch("DEFAULT_BACKLOG_URL", ""),
    backlog_email: ENV.fetch("DEFAULT_BACKLOG_EMAIL", ""),
    board_id: ENV.fetch("DEFAULT_BACKLOG_BOARD_ID", "0").to_i,
    user_backlog_id: ENV.fetch("DEFAULT_BACKLOG_USER_ID", "0").to_i
  }.freeze
end
