require "warden"

# 認証系エンドポイントのブルートフォース / 大量登録対策。
# puma は単一プロセス運用のため、カウンタはプロセス内の MemoryStore に置く
# （production の Rails.cache は file_store なので使わない）。
Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

# テスト環境では既定で無効。レート制限を検証するテストが setup で true にする。
Rack::Attack.enabled = false if Rails.env.test?

module RackAttackRules
  SIGN_IN_PATH = "/api/v1/auth/sign_in".freeze
  SIGN_UP_PATH = "/api/v1/auth/sign_up".freeze
  PASSWORD_PATH = "/api/v1/auth/password".freeze

  POST_ONLY = %w[POST].freeze
  PASSWORD_METHODS = %w[POST PUT PATCH].freeze

  SIGN_IN_LIMIT_PER_IP = 10
  SIGN_IN_PERIOD_SECONDS = 60
  SIGN_UP_LIMIT_PER_IP = 5
  PASSWORD_LIMIT_PER_IP = 5
  HOURLY_PERIOD_SECONDS = 3600

  # email 単位の制限: 認証に失敗した試行だけを固定窓で数える。
  # 失敗のみ計数のため、攻撃者が 10 分に 10 回の誤パスワードを送り続ける限り当該アカウントはログイン不可になる
  # （Devise lockable と同じトレードオフ。本人の正常利用は失敗しない限り影響なし）。
  # 成功・失敗を問わず数えると、認証不要で毎分数回 POST するだけで本人を締め出せてしまうため失敗に限定している。
  EMAIL_FAILURE_LIMIT = 10
  EMAIL_FAILURE_PERIOD_SECONDS = 600
  EMAIL_FAILURE_KEY_PREFIX = "sign_in/email_fail".freeze

  # sign_in で受け付けるボディの上限。超過は入口で 413 にする（email 抽出もこの範囲でしか読まない）
  MAX_JSON_BODY_BYTES = 16 * 1024

  # クエリ / ボディの解析失敗として握り潰す例外。
  # Rack::BadRequest は Rack の不正入力例外(InvalidParameterError / ParameterTypeError / QueryLimitError /
  # multipart 系)が include するモジュール。素の ArgumentError は無関係なバグを隠すので捕捉しない。
  PARSE_ERRORS = [
    JSON::ParserError, EncodingError, EOFError, RangeError, Rack::BadRequest
  ].freeze

  # email の取得元。Rails / Devise がクエリとボディのどれを採るかに追従するのは脆いので、
  # 候補をすべて集め、同一 email は取得元によらず 1 カウンタで数える。[名前, 解析結果の種別, user 配下か]
  EMAIL_SOURCES = {
    "query_user" => [ :query, true ],
    "query_top" => [ :query, false ],
    "body_user" => [ :body, true ],
    "body_top" => [ :body, false ]
  }.freeze

  PARSED_QUERY_ENV_KEY = "rack_attack.parsed_query".freeze
  PARSED_BODY_ENV_KEY = "rack_attack.parsed_body".freeze

  # Fly のプロキシがこのヘッダを上書きして付与するためクライアントは偽装できない。
  # X-Forwarded-For の末尾は Fly 側のパブリック IP なので request.ip は全クライアントで同一になってしまう。
  FLY_CLIENT_IP_HEADER = "HTTP_FLY_CLIENT_IP".freeze

  BLOCK_OVERSIZED = "sign_in/oversized_body".freeze
  BLOCK_NON_STRING_EMAIL = "sign_in/non_string_email".freeze
  BLOCK_EMAIL_LIMIT = "sign_in/email".freeze

  THROTTLED_MESSAGE = "リクエストが多すぎます。しばらく時間をおいて再度お試しください。".freeze
  OVERSIZED_MESSAGE = "リクエストが大きすぎます。".freeze
  MALFORMED_MESSAGE = "リクエストの形式が正しくありません。".freeze

  module_function

  # 連続スラッシュ・末尾スラッシュ・フォーマット拡張子(.json / .xml 等)の揺れを吸収したパス
  def client_ip(request)
    fly_client_ip = request.get_header(FLY_CLIENT_IP_HEADER).to_s.strip
    fly_client_ip.empty? ? request.ip : fly_client_ip
  end

  def normalized_path(request)
    request.path.squeeze("/").chomp("/").sub(/\.[A-Za-z0-9]+\z/, "")
  end

  def target?(request, path, methods)
    methods.include?(request.request_method) && normalized_path(request) == path
  end

  def sign_in_post?(request)
    target?(request, SIGN_IN_PATH, POST_ONLY)
  end

  # --- 入口拒否 (blocklist) -------------------------------------------------

  # Content-Length が上限超、または長さ不明で chunked 転送
  def oversized_body?(request)
    content_length = request.content_length
    return content_length.to_i > MAX_JSON_BODY_BYTES if content_length

    request.get_header("HTTP_TRANSFER_ENCODING").to_s.downcase.include?("chunked")
  end

  # email 候補が nil / String 以外（Array / Hash 等）
  def non_string_email?(request)
    EMAIL_SOURCES.keys.any? do |source_name|
      raw_email = raw_email_for(request, source_name)
      !raw_email.nil? && !raw_email.is_a?(String)
    end
  end

  # --- email 計数 ------------------------------------------------------------

  # 取得元をまたいだ正規化済み email 候補（重複除去）。同一 email を取得元ごとに数えると実効上限が倍になる。
  def candidate_emails(request)
    EMAIL_SOURCES.keys.filter_map { |source_name| normalized_email(request, source_name) }.uniq
  end

  # blocklist 用。加算はせず読むだけ（加算は Warden の失敗フックのみ）。1 つでも上限以上なら true。
  def email_limit_exceeded?(request)
    candidate_emails(request).any? do |email|
      Rack::Attack.cache.store.read(email_failure_store_key(email)).to_i >= EMAIL_FAILURE_LIMIT
    end
  end

  # sign_in の認証失敗を、リクエストに含まれる全 email 候補について加算する。
  # Warden は失敗アプリ呼び出し前に PATH_INFO を "/unauthenticated" に書き換えるため、
  # 元のパスは options[:attempted_path] から復元して sign_in 判定に使う（メソッド・ボディ・メモ化は env のまま）。
  def record_sign_in_failure(env, options)
    return unless Rack::Attack.enabled

    attempted_path = options[:attempted_path].to_s.split("?", 2).first.to_s
    request = Rack::Attack::Request.new(env.merge("PATH_INFO" => attempted_path))
    return unless sign_in_post?(request)

    candidate_emails(request).each do |email|
      Rack::Attack.cache.count("#{EMAIL_FAILURE_KEY_PREFIX}:#{email}", EMAIL_FAILURE_PERIOD_SECONDS)
    end
  end

  # 認証成功時、認証されたユーザー自身の email の現在窓の失敗カウンタだけを消す（成功した本人を過去の誤入力で締め出さない）。
  # リクエスト内の他の取得元の email まで消すと、攻撃者が自分のアカウントで成功しつつ被害者 email を混ぜて
  # 被害者の失敗カウンタをリセットできてしまうため、candidate_emails は使わない。
  def clear_sign_in_failures(env, user)
    return unless Rack::Attack.enabled
    return unless sign_in_post?(Rack::Attack::Request.new(env))

    user_email = user.respond_to?(:email) ? user.email.to_s.strip.downcase : nil
    return if user_email.blank?

    Rack::Attack.cache.store.delete(email_failure_store_key(user_email))
  end

  # Rack::Attack::Cache#count (rack-attack 6.8.0 cache.rb key_and_expiry) と同じ
  # "#{prefix}:#{Time.now.to_i / period}:#{unprefixed_key}" の固定窓キー。
  # count は加算専用で読み取り API が無いため、読み取り・削除側でも同じ規則を再現する。
  def email_failure_store_key(email)
    window_index = (Time.now.to_i / EMAIL_FAILURE_PERIOD_SECONDS).to_i
    "#{Rack::Attack.cache.prefix}:#{window_index}:#{EMAIL_FAILURE_KEY_PREFIX}:#{email}"
  end

  # 取得元ごとの正規化済み email。取り出せない・空なら nil（カウント対象外）。
  def normalized_email(request, source_name)
    raw_email = raw_email_for(request, source_name)
    return nil unless raw_email.is_a?(String) && raw_email.valid_encoding?

    normalized = raw_email.strip.downcase
    normalized.empty? ? nil : normalized
  end

  def raw_email_for(request, source_name)
    parsed_kind, under_user = EMAIL_SOURCES.fetch(source_name)
    parsed = parsed_kind == :query ? parsed_query(request) : parsed_body(request)
    return nil unless parsed.is_a?(Hash)

    if under_user
      user_params = parsed["user"]
      user_params["email"] if user_params.is_a?(Hash)
    else
      parsed["email"]
    end
  end

  # 解析結果は 1 リクエスト内で複数の throttle / blocklist から呼ばれるため env にメモ化する。
  # 失敗は空 Hash として記憶し、再解析しない。
  def parsed_query(request)
    memoize(request, PARSED_QUERY_ENV_KEY) { request.GET }
  end

  def parsed_body(request)
    memoize(request, PARSED_BODY_ENV_KEY) { parse_body(request) }
  end

  def memoize(request, env_key)
    return request.env[env_key] if request.env.key?(env_key)

    request.env[env_key] = begin
      yield
    rescue *PARSE_ERRORS
      {}
    end
  end

  # 上限超・サイズ不明のボディは読まない（blocklist が先に弾くが二重防御）
  def parse_body(request)
    content_length = request.content_length
    return {} if content_length.nil? || content_length.to_i > MAX_JSON_BODY_BYTES

    request.media_type.to_s.include?("json") ? parse_json_body(request) : request.POST
  end

  def parse_json_body(request)
    raw_body = read_limited_body(request)
    return {} if raw_body.nil?

    JSON.parse(raw_body.force_encoding(Encoding::UTF_8))
  end

  # Content-Length と実体がずれても上限 +1 バイトまでしか読まない。超過なら nil。
  def read_limited_body(request)
    body = request.body
    begin
      raw_body = body.read(MAX_JSON_BODY_BYTES + 1).to_s.dup
    ensure
      body.rewind if body.respond_to?(:rewind)
    end
    raw_body.bytesize > MAX_JSON_BODY_BYTES ? nil : raw_body
  end

  # 固定窓の残り秒数。Rack::Attack.cache.last_epoch_time は共有状態でスレッド間汚染するため使わない。
  def retry_after_seconds(period_seconds)
    remaining = period_seconds - (Time.now.to_i % period_seconds)
    [ remaining.to_i, 1 ].max
  end
end

# oversized を先に定義する（blocklist は定義順に評価され、ボディ解析は上限内でしか走らせない）
Rack::Attack.blocklist(RackAttackRules::BLOCK_OVERSIZED) do |request|
  RackAttackRules.sign_in_post?(request) && RackAttackRules.oversized_body?(request)
end

Rack::Attack.blocklist(RackAttackRules::BLOCK_NON_STRING_EMAIL) do |request|
  RackAttackRules.sign_in_post?(request) && RackAttackRules.non_string_email?(request)
end

# 失敗回数が上限に達した email への試行は、パスワード検証に進ませず blocklist 段で 429 にする。
# 429 は IP throttle より先に返すため、email 超過のリクエストは IP カウンタに入らない
# （既に拒否済みで、異なる email を回す総当たりは IP 側で数えられるので制限の意味は弱まらない）
Rack::Attack.blocklist(RackAttackRules::BLOCK_EMAIL_LIMIT) do |request|
  RackAttackRules.sign_in_post?(request) && RackAttackRules.email_limit_exceeded?(request)
end

Rack::Attack.throttle("sign_in/ip", limit: RackAttackRules::SIGN_IN_LIMIT_PER_IP, period: RackAttackRules::SIGN_IN_PERIOD_SECONDS) do |request|
  RackAttackRules.client_ip(request) if RackAttackRules.sign_in_post?(request)
end

Rack::Attack.throttle("sign_up/ip", limit: RackAttackRules::SIGN_UP_LIMIT_PER_IP, period: RackAttackRules::HOURLY_PERIOD_SECONDS) do |request|
  RackAttackRules.client_ip(request) if RackAttackRules.target?(request, RackAttackRules::SIGN_UP_PATH, RackAttackRules::POST_ONLY)
end

Rack::Attack.throttle("password/ip", limit: RackAttackRules::PASSWORD_LIMIT_PER_IP, period: RackAttackRules::HOURLY_PERIOD_SECONDS) do |request|
  RackAttackRules.client_ip(request) if RackAttackRules.target?(request, RackAttackRules::PASSWORD_PATH, RackAttackRules::PASSWORD_METHODS)
end

Rack::Attack.throttled_responder = lambda do |request|
  throttle_period = request.env.dig("rack.attack.match_data", :period) || 1
  retry_after = RackAttackRules.retry_after_seconds(throttle_period)
  [
    429,
    { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
    [ { error: RackAttackRules::THROTTLED_MESSAGE }.to_json ]
  ]
end

Rack::Attack.blocklisted_responder = lambda do |request|
  matched = request.env["rack.attack.matched"]
  if matched == RackAttackRules::BLOCK_EMAIL_LIMIT
    retry_after = RackAttackRules.retry_after_seconds(RackAttackRules::EMAIL_FAILURE_PERIOD_SECONDS)
    next [
      429,
      { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
      [ { error: RackAttackRules::THROTTLED_MESSAGE }.to_json ]
    ]
  end

  oversized = matched == RackAttackRules::BLOCK_OVERSIZED
  status = oversized ? 413 : 400
  message = oversized ? RackAttackRules::OVERSIZED_MESSAGE : RackAttackRules::MALFORMED_MESSAGE
  [ status, { "Content-Type" => "application/json" }, [ { error: message }.to_json ] ]
end

# 認証失敗のみ email 別に数える（sign_in 以外のパスの失敗は record_sign_in_failure 側で無視される）
Warden::Manager.before_failure do |env, options|
  RackAttackRules.record_sign_in_failure(env, options)
end

Warden::Manager.after_set_user except: :fetch do |user, auth, options|
  RackAttackRules.clear_sign_in_failures(auth.env, user) if options[:event] == :authentication
end
