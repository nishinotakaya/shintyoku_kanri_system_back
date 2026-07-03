# Canva Connect API クライアント。
# OAuth2(Authorization Code + PKCE)で取得したユーザートークンを使い、
# アセットupload → デザイン作成(編集URL取得) → PNG書き出し を行う。
#
# 必要 ENV:
#   CANVA_CLIENT_ID / CANVA_CLIENT_SECRET / CANVA_REDIRECT_URI
class CanvaClient
  AUTH_URL  = "https://www.canva.com/api/oauth/authorize".freeze
  TOKEN_URL = "https://api.canva.com/rest/v1/oauth/token".freeze
  API_BASE  = "https://api.canva.com/rest/v1".freeze
  SCOPES    = %w[asset:read asset:write design:content:read design:content:write design:meta:read].freeze

  class NotConnected < StandardError; end
  class ConfigMissing < StandardError; end

  def self.client_id      = ENV["CANVA_CLIENT_ID"]
  # secret は CANVA_API_SECRET を正とし、CANVA_CLIENT_SECRET も後方互換で許可。
  def self.client_secret  = ENV["CANVA_API_SECRET"].presence || ENV["CANVA_CLIENT_SECRET"]
  def self.redirect_uri   = ENV.fetch("CANVA_REDIRECT_URI", "http://127.0.0.1:3001/api/v1/canva/callback")
  def self.configured?    = client_id.present? && client_secret.present?

  # 認可URL(PKCE)。code_challenge は SHA256(code_verifier) を base64url。
  def self.authorize_url(state:, code_challenge:)
    raise ConfigMissing, "CANVA_CLIENT_ID/SECRET が未設定です" unless configured?

    params = {
      response_type: "code",
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: SCOPES.join(" "),
      state: state,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    }
    "#{AUTH_URL}?#{URI.encode_www_form(params)}"
  end

  # 認可コード → トークン交換。{access_token, refresh_token, expires_in}
  def self.exchange_code(code:, code_verifier:)
    post_token(
      grant_type: "authorization_code",
      code: code,
      code_verifier: code_verifier,
      redirect_uri: redirect_uri
    )
  end

  def self.refresh(refresh_token:)
    post_token(grant_type: "refresh_token", refresh_token: refresh_token)
  end

  def self.post_token(form)
    raise ConfigMissing, "CANVA_CLIENT_ID/SECRET が未設定です" unless configured?

    uri = URI(TOKEN_URL)
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 60 }
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/x-www-form-urlencoded"
    req.basic_auth(client_id, client_secret)
    req.body = URI.encode_www_form(form)

    res = http.request(req)
    raise "Canva トークンエラー (#{res.code}): #{res.body.to_s.slice(0, 200)}" unless res.code.start_with?("2")
    JSON.parse(res.body)
  end

  # ---- インスタンス: ユーザーのトークンで API を叩く ----

  def initialize(user)
    @user = user
    raise NotConnected, "Canva に接続されていません" if @user.canva_refresh_token.blank?
  end

  def connected? = @user.canva_refresh_token.present?

  # 背景PNG(バイナリ) → Canva アセットID
  def upload_asset(bytes, name:)
    job = request(:post, "/asset-uploads", body: bytes, raw: true, headers: {
      "Content-Type" => "application/octet-stream",
      "Asset-Upload-Metadata" => { name_base64: Base64.strict_encode64(name.to_s) }.to_json
    })
    job = poll("/asset-uploads/#{job.dig('job', 'id')}", key: "job") until job.dig("job", "status") == "success" || job.dig("job", "status") == "failed"
    raise "Canva アセットupload失敗" unless job.dig("job", "status") == "success"
    job.dig("job", "asset", "id")
  end

  # アセットから新規デザインを作成。{ design_id:, edit_url: }
  def create_design_from_asset(asset_id, title:)
    res = request(:post, "/designs", json: {
      design_type: { type: "preset", name: "presentation" },
      asset_id: asset_id,
      title: title
    })
    design = res["design"] || {}
    { design_id: design["id"], edit_url: design.dig("urls", "edit_url") }
  end

  # ブランドテンプレートを Autofill して「編集可能なテキスト＋背景画像」のデザインを作る。
  # template のフィールド名: background(画像) / main_copy / sub_copy / panel_left / panel_mid / panel_right(テキスト)
  # => { design_id:, edit_url: }
  def autofill(brand_template_id, title:, image_asset_id: nil, texts: {})
    data = {}
    data["background"] = { type: "image", asset_id: image_asset_id } if image_asset_id
    texts.each { |field, value| data[field.to_s] = { type: "text", text: value.to_s } if value.to_s.strip.present? }
    res = request(:post, "/autofills", json: { brand_template_id: brand_template_id, title: title, data: data })
    job_id = res.dig("job", "id")
    job = poll("/autofills/#{job_id}", key: "job") until %w[success failed].include?(job.dig("job", "status"))
    raise "Canva autofill失敗: #{job.dig('job', 'error', 'message') || job.dig('job', 'status')}" unless job.dig("job", "status") == "success"
    design = job.dig("job", "result", "design") || {}
    { design_id: design["id"], edit_url: design.dig("urls", "edit_url") }
  end

  # デザインを PNG 書き出し → 画像URL(配列の先頭)
  def export_png(design_id)
    res = request(:post, "/exports", json: { design_id: design_id, format: { type: "png" } })
    job_id = res.dig("job", "id")
    job = poll("/exports/#{job_id}", key: "job") until %w[success failed].include?(job.dig("job", "status"))
    raise "Canva PNG書き出し失敗" unless job.dig("job", "status") == "success"
    Array(job.dig("job", "urls")).first
  end

  private

  # 期限切れなら refresh して DB 保存。有効な access_token を返す。
  def access_token
    if @user.canva_token_expires_at.nil? || @user.canva_token_expires_at < 1.minute.from_now
      data = self.class.refresh(refresh_token: @user.canva_refresh_token)
      @user.update!(
        canva_access_token: data["access_token"],
        canva_refresh_token: data["refresh_token"].presence || @user.canva_refresh_token,
        canva_token_expires_at: Time.current + data["expires_in"].to_i.seconds
      )
    end
    @user.canva_access_token
  end

  def poll(path, key:)
    sleep 1
    request(:get, path)
  end

  def request(method, path, json: nil, body: nil, raw: false, headers: {})
    uri = URI("#{API_BASE}#{path}")
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 120 }
    klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
    req = klass.new(uri.request_uri)
    req["Authorization"] = "Bearer #{access_token}"
    if json
      req["Content-Type"] = "application/json"
      req.body = json.to_json
    elsif raw
      req.body = body
    end
    headers.each { |k, v| req[k] = v }

    res = http.request(req)
    raise "Canva APIエラー (#{res.code} #{path}): #{res.body.to_s.slice(0, 200)}" unless res.code.start_with?("2")
    res.body.present? ? JSON.parse(res.body) : {}
  end
end
