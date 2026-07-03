require "signet/oauth_2/client"

# ユーザーに保存された Google OAuth トークンから Signet クライアントを作る共通ヘルパー。
# 期限切れなら refresh して User に保存し直す。
# (既存 GoogleSheetsImporter#build_auth と同等のロジックを集約)
module GoogleAuth
  module_function

  # Google 連携トークンを使うユーザーを解決する。
  # 操作者(operator) がトークンを持っていればそれを、無ければ (= Google 未ログイン。例: 岩切/加藤)
  # Google 連携済みの admin (西野) のトークンにフォールバックする。
  def credential_user(operator)
    return operator if has_token?(operator)
    User.where.not(google_refresh_token: [ nil, "" ]).detect(&:admin?) ||
      User.where.not(google_access_token: [ nil, "" ]).detect(&:admin?) ||
      operator
  end

  def has_token?(user)
    user.present? && (user.google_access_token.present? || user.google_refresh_token.present?)
  end

  # 書き込み(export)用のトークン保有者を解決する。
  # 書き込みは write スコープを持つ管理者(西野)のトークンで行うのが確実なので、
  # 操作者が誰であろうと「トークンを持つ管理者」を優先する（無ければ操作者にフォールバック）。
  def writer_user(operator)
    admin = User.where.not(google_refresh_token: [ nil, "" ]).order(:id).detect(&:admin?) ||
            User.where.not(google_access_token: [ nil, "" ]).order(:id).detect(&:admin?)
    (admin if has_token?(admin)) || credential_user(operator)
  end

  def build_writer(operator)
    user = writer_user(operator)
    raise "Google 連携アカウント(書き込み用)が見つかりません。管理者(西野さん)が Google ログインしてください。" unless has_token?(user)
    build(user)
  end

  # 操作者にトークンが無ければ admin にフォールバックして Signet を作る。
  def build_with_fallback(operator)
    user = credential_user(operator)
    unless has_token?(user)
      raise "Google 連携アカウントが見つかりません。管理者(西野さん)が一度 Google ログインするか、シートを『リンクを知っている全員(閲覧可)』に設定してください。"
    end
    build(user)
  end

  def build(user)
    if user.google_access_token.blank? && user.google_refresh_token.blank?
      raise "Google アクセストークンがありません。再度 Google ログインしてください。"
    end

    auth = Signet::OAuth2::Client.new(
      token_credential_uri: "https://oauth2.googleapis.com/token",
      client_id: ENV["GOOGLE_CLIENT_ID"],
      client_secret: ENV["GOOGLE_CLIENT_SECRET"],
      access_token: user.google_access_token,
      refresh_token: user.google_refresh_token
    )

    if user.google_token_expires_at && user.google_token_expires_at < Time.current && user.google_refresh_token.present?
      auth.fetch_access_token!
      user.update!(
        google_access_token: auth.access_token,
        google_token_expires_at: Time.current + 3600
      )
    end

    auth
  end
end
