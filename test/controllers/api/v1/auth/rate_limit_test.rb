require "test_helper"

# AC-01: rack-attack による認証系エンドポイントのレート制限
class Api::V1::Auth::RateLimitTest < ActionDispatch::IntegrationTest
  SIGN_IN_PATH = "/api/v1/auth/sign_in".freeze
  SIGN_UP_PATH = "/api/v1/auth/sign_up".freeze
  PASSWORD_PATH = "/api/v1/auth/password".freeze

  # URL 表記を変えても devise の sessions#create に到達する経路（回避経路になり得るもの）。
  # recognize_path / 実リクエストで到達を確認済み。sign%5Fin は 404、SIGN_IN は別ルートで回避経路にならないため含めない。
  SIGN_IN_PATH_VARIANTS = {
    "フォーマット付き(.xml)" => "/api/v1/auth/sign_in.xml",
    "連続スラッシュ" => "/api/v1//auth/sign_in",
    "末尾スラッシュ" => "/api/v1/auth/sign_in/"
  }.freeze

  EMAIL_FAILURE_LIMIT = 10
  # email 単位は 600 秒の固定窓。固定時刻(1時間窓の先頭+5秒)なら残り 595 秒。
  EMAIL_RETRY_AFTER = 595
  KNOWN_PASSWORD = "correct-password-123".freeze

  setup do
    @original_enabled = Rack::Attack.enabled
    @original_cache_store = Rack::Attack.cache.store
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    @sequence = 0
    @created_users = []
    # rack-attack は epoch 基準の固定窓(Time.now.to_i)。実時計だと窓境界を跨いでカウンタが
    # リセットされ flake になるため、1時間窓の先頭+5秒に固定して 60秒/3600秒窓の境界から離す。
    @frozen_time = Time.zone.at((Time.now.to_i / 3600) * 3600 + 5)
    travel_to(@frozen_time)
  end

  teardown do
    @created_users.each(&:destroy)
    travel_back
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = @original_enabled
    Rack::Attack.cache.store = @original_cache_store
  end

  test "同一IPからのsign_inは10回までは429にならず11回目で429になる" do
    10.times do |attempt_index|
      post_sign_in(email: unique_email, ip: "198.51.100.10")
      assert_not_equal 429, response.status, "#{attempt_index + 1} 回目で 429 になった"
    end

    post_sign_in(email: unique_email, ip: "198.51.100.10")
    assert_equal 429, response.status
  end

  test "IP制限に達した後でも別IPからのsign_inは429にならない" do
    11.times { post_sign_in(email: unique_email, ip: "198.51.100.20") }
    assert_equal 429, response.status

    post_sign_in(email: unique_email, ip: "198.51.100.21")
    assert_not_equal 429, response.status
  end

  test "同一emailは表記ゆれ(大文字・前後空白)を同一視しIPが違っても失敗10回までで11回目が429" do
    email_variants = [
      "foo@example.com", " Foo@Example.com ", "FOO@EXAMPLE.COM",
      "foo@example.com ", " foo@Example.com"
    ] * 2
    email_variants.each_with_index do |email, attempt_index|
      post_sign_in(email: email, ip: "203.0.113.#{attempt_index + 1}")
      assert_not_equal 429, response.status, "#{attempt_index + 1} 回目で 429 になった"
    end

    post_sign_in(email: " fOo@example.com", ip: "203.0.113.99")
    assert_equal 429, response.status
  end

  test "別emailなら同一email制限の影響を受けない" do
    (EMAIL_FAILURE_LIMIT + 1).times { |index| post_sign_in(email: "same@example.com", ip: "203.0.113.#{index + 1}") }
    assert_equal 429, response.status

    post_sign_in(email: "other@example.com", ip: "203.0.113.50")
    assert_not_equal 429, response.status
  end

  test "429応答はJSONのerrorメッセージとRetry-Afterヘッダを持つ" do
    11.times { post_sign_in(email: unique_email, ip: "198.51.100.30") }

    assert_equal 429, response.status
    assert_match %r{application/json}, response.content_type.to_s
    body = JSON.parse(response.body)
    assert_kind_of String, body["error"]
    assert_not_empty body["error"]
    retry_after = response.headers["Retry-After"]
    assert_not_nil retry_after
    assert_match(/\A[1-9]\d*\z/, retry_after.to_s)
    # sign_in/ip は 60 秒の固定窓。固定時刻(窓先頭+5秒)なら残り 55 秒。
    sign_in_period = 60
    assert_equal sign_in_period - (@frozen_time.to_i % sign_in_period), retry_after.to_i
  end

  test "sign_upは同一IPで5回までは429にならず6回目で429になる" do
    5.times do |attempt_index|
      post SIGN_UP_PATH, params: { user: { email: unique_email, password: "password123" } },
                         as: :json, headers: { "REMOTE_ADDR" => "198.51.100.40" }
      assert_not_equal 429, response.status, "#{attempt_index + 1} 回目で 429 になった"
    end

    post SIGN_UP_PATH, params: { user: { email: unique_email, password: "password123" } },
                       as: :json, headers: { "REMOTE_ADDR" => "198.51.100.40" }
    assert_equal 429, response.status
  end

  test "passwordリセット(POST)は同一IPで5回までは429にならず6回目で429になる" do
    5.times do |attempt_index|
      post PASSWORD_PATH, params: { user: { email: unique_email } },
                          as: :json, headers: { "REMOTE_ADDR" => "198.51.100.50" }
      assert_not_equal 429, response.status, "#{attempt_index + 1} 回目で 429 になった"
    end

    post PASSWORD_PATH, params: { user: { email: unique_email } },
                        as: :json, headers: { "REMOTE_ADDR" => "198.51.100.50" }
    assert_equal 429, response.status
  end

  test "認証系以外のパス(GET /up)は何度叩いても429にならない" do
    30.times do
      get "/up", headers: { "REMOTE_ADDR" => "198.51.100.60" }
      assert_not_equal 429, response.status
    end
  end

  test "テスト環境の既定ではレート制限は無効" do
    Rack::Attack.enabled = false
    15.times { post_sign_in(email: unique_email, ip: "198.51.100.70") }
    assert_not_equal 429, response.status
  end

  SIGN_IN_PATH_VARIANTS.each do |label, variant_path|
    test "sign_inのパス表記揺れ(#{label})でIP制限を回避できず11回目で429になる" do
      11.times do |attempt_index|
        post variant_path,
             params: { user: { email: unique_email, password: "wrong-password" } },
             as: :json, headers: { "REMOTE_ADDR" => "192.0.2.10" }
        assert_not_equal 404, response.status, "#{variant_path} がルートに到達していない"
        assert_not_equal 429, response.status, "#{attempt_index + 1} 回目で 429 になった" if attempt_index < 10
      end
      assert_equal 429, response.status
    end

    test "sign_inのパス表記揺れ(#{label})と正規パスを混ぜても同じIPカウンタで11回目が429になる" do
      11.times do |attempt_index|
        path = attempt_index.even? ? SIGN_IN_PATH : variant_path
        post path,
             params: { user: { email: unique_email, password: "wrong-password" } },
             as: :json, headers: { "REMOTE_ADDR" => "192.0.2.11" }
      end
      assert_equal 429, response.status
    end
  end

  test "emailをクエリ文字列に入れてもボディのemailで制限され失敗11回目が429になる" do
    10.times do |index|
      post "#{SIGN_IN_PATH}?user[email]=random#{index}@example.com",
           params: { user: { email: "victim@example.com", password: "x" } },
           as: :json, headers: { "REMOTE_ADDR" => "192.0.2.#{20 + index}" }
      assert_not_equal 429, response.status
    end

    post "#{SIGN_IN_PATH}?user[email]=random99@example.com",
         params: { user: { email: "victim@example.com", password: "x" } },
         as: :json, headers: { "REMOTE_ADDR" => "192.0.2.99" }
    assert_equal 429, response.status
  end

  test "form形式(JSONでない)のsign_inでもemail制限が効き失敗11回目が429になる" do
    10.times do |index|
      post SIGN_IN_PATH,
           params: { user: { email: "form-victim@example.com", password: "x" } },
           headers: { "REMOTE_ADDR" => "192.0.2.#{40 + index}" }
      assert_not_equal 429, response.status
    end

    post SIGN_IN_PATH,
         params: { user: { email: "FORM-victim@example.com", password: "x" } },
         headers: { "REMOTE_ADDR" => "192.0.2.99" }
    assert_equal 429, response.status
  end

  test "不正JSONボディのsign_inでも500にならず、同一IPの11回目は429になる(throttle自体が生きている)" do
    assert_ip_throttle_survives("192.0.2.60") do |ip|
      post SIGN_IN_PATH, params: "{not json", headers: json_headers(ip)
    end
  end

  test "不正UTF-8バイトを含むJSONボディのsign_inでも500にならず、同一IPの11回目は429になる" do
    invalid_body = "{\"user\":{\"email\":\"a\xFF\xFE@example.com\",\"password\":\"x\"}}".b
    assert_ip_throttle_survives("192.0.2.61") do |ip|
      post SIGN_IN_PATH, params: invalid_body, headers: json_headers(ip)
    end
  end

  test "16KB超のJSONボディのsign_inは1回目から413とJSONのerrorを返す" do
    oversized_body = { user: { email: "big@example.com", password: "x" }, padding: "A" * 20_000 }.to_json
    assert_operator oversized_body.bytesize, :>, 16 * 1024

    post SIGN_IN_PATH, params: oversized_body, headers: json_headers("192.0.2.62")
    assert_equal 413, response.status
    assert_match %r{application/json}, response.content_type.to_s
    assert_kind_of String, JSON.parse(response.body)["error"]
    assert_not_empty JSON.parse(response.body)["error"]
  end

  test "16KB超のformボディのsign_inは413になる" do
    post SIGN_IN_PATH,
         params: { user: { email: "big-form@example.com", password: "x" }, padding: "A" * 20_000 },
         headers: { "REMOTE_ADDR" => "192.0.2.63" }
    assert_equal 413, response.status
    assert_kind_of String, JSON.parse(response.body)["error"]
  end

  test "ちょうど16KBのJSONボディは413にならない(境界)" do
    base_body = { user: { email: "edge@example.com", password: "x" }, padding: "" }.to_json
    boundary_body = { user: { email: "edge@example.com", password: "x" }, padding: "A" * (16 * 1024 - base_body.bytesize) }.to_json
    assert_equal 16 * 1024, boundary_body.bytesize

    post SIGN_IN_PATH, params: boundary_body, headers: json_headers("192.0.2.64")
    assert_not_equal 413, response.status
  end

  test "クエリのみ(ボディ無し)のuser[email]でもIPが違っても失敗11回目が429になる" do
    10.times do |index|
      post "#{SIGN_IN_PATH}?user[email]=victim@example.com&user[password]=x",
           headers: { "REMOTE_ADDR" => "192.0.2.#{100 + index}" }
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    post "#{SIGN_IN_PATH}?user[email]=victim@example.com&user[password]=x",
         headers: { "REMOTE_ADDR" => "192.0.2.199" }
    assert_equal 429, response.status
  end

  test "クエリuser[email]にvictimを置き、ボディはtop-levelのランダムemailでもIPが違えば失敗11回目が429になる" do
    10.times do |index|
      post "#{SIGN_IN_PATH}?user[email]=victim@example.com",
           params: { email: "rand#{index}@example.com", password: "x" },
           as: :json, headers: { "REMOTE_ADDR" => "192.0.2.#{110 + index}" }
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    post "#{SIGN_IN_PATH}?user[email]=victim@example.com",
         params: { email: "rand99@example.com", password: "x" },
         as: :json, headers: { "REMOTE_ADDR" => "192.0.2.198" }
    assert_equal 429, response.status
  end

  test "クエリのトップレベルemail(userキー無し)でもIPが違えば失敗11回目が429になる" do
    10.times do |index|
      post "#{SIGN_IN_PATH}?email=victim@example.com",
           headers: { "REMOTE_ADDR" => "192.0.2.#{120 + index}" }
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    post "#{SIGN_IN_PATH}?email=victim@example.com", headers: { "REMOTE_ADDR" => "192.0.2.197" }
    assert_equal 429, response.status
  end

  test "ボディのトップレベルemail(userキー無し)でもIPが違えば失敗11回目が429になる" do
    10.times do |index|
      post SIGN_IN_PATH, params: { email: "victim@example.com", password: "x" },
                         as: :json, headers: { "REMOTE_ADDR" => "192.0.2.#{130 + index}" }
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    post SIGN_IN_PATH, params: { email: "victim@example.com", password: "x" },
                       as: :json, headers: { "REMOTE_ADDR" => "192.0.2.196" }
    assert_equal 429, response.status
  end

  test "email候補が配列(JSONボディ)のsign_inは1回目から400とJSONのerrorを返す" do
    post SIGN_IN_PATH, params: { user: { email: [ "victim@example.com" ], password: "x" } },
                       as: :json, headers: { "REMOTE_ADDR" => "192.0.2.140" }
    assert_equal 400, response.status
    assert_kind_of String, JSON.parse(response.body)["error"]
    assert_not_empty JSON.parse(response.body)["error"]
  end

  test "email候補がHash(JSONボディ)のsign_inは400になる" do
    post SIGN_IN_PATH, params: { user: { email: { a: "b" }, password: "x" } },
                       as: :json, headers: { "REMOTE_ADDR" => "192.0.2.141" }
    assert_equal 400, response.status
    assert_kind_of String, JSON.parse(response.body)["error"]
  end

  test "クエリuser[email][]=...(配列)のsign_inは400になる" do
    post "#{SIGN_IN_PATH}?user[email][]=victim@example.com", headers: { "REMOTE_ADDR" => "192.0.2.142" }
    assert_equal 400, response.status
    assert_kind_of String, JSON.parse(response.body)["error"]
  end

  test "レート制限が無効のときは入口拒否(400/413)も働かない" do
    Rack::Attack.enabled = false
    oversized_body = { user: { email: "big@example.com", password: "x" }, padding: "A" * 20_000 }.to_json

    requests = {
      "email配列" => -> { post SIGN_IN_PATH, params: { user: { email: [ "victim@example.com" ], password: "x" } }, as: :json, headers: { "REMOTE_ADDR" => "192.0.2.150" } },
      "16KB超" => -> { post SIGN_IN_PATH, params: oversized_body, headers: json_headers("192.0.2.151") }
    }
    requests.each do |label, request|
      request.call
      assert_not_equal 413, response.status, "#{label}: 無効時に413になった"
      assert_not_rack_attack_rejection(label)
    end
  end

  test "passwordのPUT・PATCH・POSTは同じIP制限(5回/時)に数えられ6回目が429になる" do
    verbs = %i[put patch post put patch]
    verbs.each do |verb|
      public_send(verb, PASSWORD_PATH, params: { user: { email: unique_email } },
                                       as: :json, headers: { "REMOTE_ADDR" => "192.0.2.70" })
      assert_not_equal 429, response.status
    end

    post PASSWORD_PATH, params: { user: { email: unique_email } },
                        as: :json, headers: { "REMOTE_ADDR" => "192.0.2.70" }
    assert_equal 429, response.status
  end

  test "initializerの既定ではテスト環境のレート制限は無効(setupの有効化前の値)" do
    assert_equal false, @original_enabled
  end

  test "取得元(クエリuser/ボディuser/ボディtop/クエリtop/form user)をローテーションしても同一emailは1カウンタで失敗11回目が429" do
    victim = "victim@example.com"
    rotations = [
      ->(ip) { post "#{SIGN_IN_PATH}?user[email]=#{victim}", headers: { "REMOTE_ADDR" => ip } },
      ->(ip) { post SIGN_IN_PATH, params: { user: { email: victim, password: "x" } }, as: :json, headers: { "REMOTE_ADDR" => ip } },
      ->(ip) { post SIGN_IN_PATH, params: { email: victim, password: "x" }, as: :json, headers: { "REMOTE_ADDR" => ip } },
      ->(ip) { post "#{SIGN_IN_PATH}?email=#{victim}", headers: { "REMOTE_ADDR" => ip } },
      ->(ip) { post SIGN_IN_PATH, params: { user: { email: victim, password: "x" } }, headers: { "REMOTE_ADDR" => ip } }
    ]
    10.times do |index|
      rotations[index % rotations.size].call("192.0.2.#{160 + index}")
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    rotations.first.call("192.0.2.230")
    assert_equal 429, response.status
    assert_equal EMAIL_RETRY_AFTER, response.headers["Retry-After"].to_i
    assert_kind_of String, JSON.parse(response.body)["error"]
  end

  test "1リクエストにクエリuser[email]とボディuser.emailで同じemailがあっても二重カウントせず失敗11回目が429" do
    10.times do |index|
      post "#{SIGN_IN_PATH}?user[email]=victim@example.com",
           params: { user: { email: "victim@example.com", password: "x" } },
           as: :json, headers: { "REMOTE_ADDR" => "192.0.2.#{170 + index}" }
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった(二重カウント)"
    end

    post "#{SIGN_IN_PATH}?user[email]=victim@example.com",
         params: { user: { email: "victim@example.com", password: "x" } },
         as: :json, headers: { "REMOTE_ADDR" => "192.0.2.239" }
    assert_equal 429, response.status
  end

  test "1リクエストにクエリuser[email]=aとボディuser.email=bを入れるとaとb両方のカウンタが増える" do
    10.times do |index|
      post "#{SIGN_IN_PATH}?user[email]=a@example.com",
           params: { user: { email: "b@example.com", password: "x" } },
           as: :json, headers: { "REMOTE_ADDR" => "192.0.2.#{180 + index}" }
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    post "#{SIGN_IN_PATH}?user[email]=a@example.com", headers: { "REMOTE_ADDR" => "192.0.2.190" }
    assert_equal 429, response.status, "a のカウンタが増えていない"

    post SIGN_IN_PATH, params: { user: { email: "b@example.com", password: "x" } },
                       as: :json, headers: { "REMOTE_ADDR" => "192.0.2.191" }
    assert_equal 429, response.status, "b のカウンタが増えていない"
  end

  test "壊れたmultipartボディのsign_inでもrack_attack.rb由来の例外が出ない" do
    broken_body = "--xxx\r\nContent-Disposition: form-data; name=\"user[email]\"\r\n\r\nvictim@example.com"
    raised = assert_no_rack_attack_failure do
      post SIGN_IN_PATH, params: broken_body,
                         headers: { "REMOTE_ADDR" => "192.0.2.195", "CONTENT_TYPE" => "multipart/form-data; boundary=xxx" }
    end
    assert_not_equal 500, response.status if raised.nil?
  end

  test "sign%5Fin表記は404でsessions#createに到達しない(回避経路ではない)" do
    status = begin
      post "/api/v1/auth/sign%5Fin", params: { user: { email: "victim@example.com", password: "x" } },
                                     as: :json, headers: { "REMOTE_ADDR" => "192.0.2.200" }
      response.status
    rescue ActionController::RoutingError
      404
    end
    assert_equal 404, status, "sign%5Fin が 404 にならず到達している(回避経路)"
  end

  # --- Fly-Client-IP によるクライアント識別 (Fly プロキシ背後では request.ip が全員同一になるため) ---

  test "REMOTE_ADDRが同じでもFly-Client-IPが違えばsign_inは別カウンタで、Aが429でもBは429にならない" do
    11.times { post_sign_in_via_fly(email: unique_email, remote_addr: "10.0.0.1", fly_client_ip: "203.0.113.1") }
    assert_equal 429, response.status

    post_sign_in_via_fly(email: unique_email, remote_addr: "10.0.0.1", fly_client_ip: "203.0.113.2")
    assert_not_equal 429, response.status
  end

  test "Fly本番の再現(REMOTE_ADDRと末尾のFly公開IPが共通・クライアントだけ違う)でもクライアントごとに別カウンタ" do
    fly_public_ip = "66.241.124.10"
    fly_internal_ip = "172.16.0.1"
    client_a = "203.0.113.11"
    client_b = "203.0.113.12"

    11.times do
      post_sign_in_via_fly(email: unique_email, remote_addr: fly_internal_ip, fly_client_ip: client_a,
                           forwarded_for: "#{client_a}, #{fly_public_ip}")
    end
    assert_equal 429, response.status

    post_sign_in_via_fly(email: unique_email, remote_addr: fly_internal_ip, fly_client_ip: client_b,
                         forwarded_for: "#{client_b}, #{fly_public_ip}")
    assert_not_equal 429, response.status
  end

  test "同一Fly-Client-IPならREMOTE_ADDRを変えても同じカウンタで11回目が429" do
    10.times do |index|
      post_sign_in_via_fly(email: unique_email, remote_addr: "10.0.1.#{index + 1}", fly_client_ip: "203.0.113.21")
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    post_sign_in_via_fly(email: unique_email, remote_addr: "10.0.1.99", fly_client_ip: "203.0.113.21")
    assert_equal 429, response.status
  end

  test "Fly-Client-IPが無ければREMOTE_ADDRで数える(別REMOTE_ADDRは別カウンタ)" do
    11.times { post_sign_in(email: unique_email, ip: "198.51.100.80") }
    assert_equal 429, response.status

    post_sign_in(email: unique_email, ip: "198.51.100.81")
    assert_not_equal 429, response.status
  end

  test "sign_upも同一Fly-Client-IPならREMOTE_ADDRを変えても6回目が429になる" do
    5.times do |index|
      post SIGN_UP_PATH, params: { user: { email: unique_email, password: "password123" } }, as: :json,
                         headers: { "REMOTE_ADDR" => "10.0.2.#{index + 1}", "Fly-Client-IP" => "203.0.113.31" }
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    post SIGN_UP_PATH, params: { user: { email: unique_email, password: "password123" } }, as: :json,
                       headers: { "REMOTE_ADDR" => "10.0.2.99", "Fly-Client-IP" => "203.0.113.31" }
    assert_equal 429, response.status
  end

  test "passwordのPOST・PUT・PATCHも同一Fly-Client-IPならREMOTE_ADDRを変えても6回目が429になる" do
    verbs = %i[post put patch post put]
    verbs.each_with_index do |verb, index|
      public_send(verb, PASSWORD_PATH, params: { user: { email: unique_email } }, as: :json,
                                       headers: { "REMOTE_ADDR" => "10.0.3.#{index + 1}", "Fly-Client-IP" => "203.0.113.41" })
      assert_not_equal 429, response.status, "#{index + 1} 回目で 429 になった"
    end

    patch PASSWORD_PATH, params: { user: { email: unique_email } }, as: :json,
                         headers: { "REMOTE_ADDR" => "10.0.3.99", "Fly-Client-IP" => "203.0.113.41" }
    assert_equal 429, response.status
  end

  # --- email 単位は「認証に失敗した試行」だけを数える(10回失敗 / 600秒窓) ---

  test "Rack::Attack有効のまま正しい資格情報でsign_inすると200とBearer JWTが返る" do
    user = create_known_user
    post_credentials(email: user.email, password: KNOWN_PASSWORD, ip: next_ip)

    assert_equal 200, response.status
    assert_match(/\ABearer .+\..+\..+\z/, response.headers["Authorization"].to_s)
  end

  test "正しい資格情報なら12回連続でsign_inしても429にならない(成功は数えない)" do
    user = create_known_user
    12.times do |attempt_index|
      post_credentials(email: user.email, password: KNOWN_PASSWORD, ip: next_ip)
      assert_equal 200, response.status, "#{attempt_index + 1} 回目が 200 でない(#{response.status})"
      discard_session_cookie
    end
  end

  test "誤パスワード10回の後は11回目が正しいパスワードでも429でRetry-Afterは600秒窓の残り" do
    user = create_known_user
    EMAIL_FAILURE_LIMIT.times do |attempt_index|
      post_credentials(email: user.email, password: "wrong-password", ip: next_ip)
      assert_equal 401, response.status, "#{attempt_index + 1} 回目が 401 でない(#{response.status})"
    end

    post_credentials(email: user.email, password: KNOWN_PASSWORD, ip: next_ip)
    assert_equal 429, response.status
    assert_equal EMAIL_RETRY_AFTER, response.headers["Retry-After"].to_i
    assert_kind_of String, JSON.parse(response.body)["error"]
  end

  test "誤パスワード9回の後に成功するとカウンタがリセットされ、再び10回失敗するまで429にならない" do
    user = create_known_user
    (EMAIL_FAILURE_LIMIT - 1).times { post_credentials(email: user.email, password: "wrong-password", ip: next_ip) }

    post_credentials(email: user.email, password: KNOWN_PASSWORD, ip: next_ip)
    assert_equal 200, response.status
    discard_session_cookie

    EMAIL_FAILURE_LIMIT.times do |attempt_index|
      post_credentials(email: user.email, password: "wrong-password", ip: next_ip)
      assert_not_equal 429, response.status, "リセット後 #{attempt_index + 1} 回目で 429 になった"
    end

    post_credentials(email: user.email, password: "wrong-password", ip: next_ip)
    assert_equal 429, response.status
  end

  VICTIM_EMAIL = "victim-reset@example.com".freeze

  # 成功時に消してよいのは認証されたユーザー自身のemailのカウンタだけ。
  # 攻撃者が自分のアカウントで成功しつつ、被害者emailをDeviseが読まない取得元に混ぜても消せない。
  # (クエリuser[email]=victimはボディのuserハッシュを潰して攻撃者の認証が成立しないため、
  #  攻撃者をクエリuser[email]で認証させ、被害者をボディのトップレベルemailに置く形を選んだ)
  {
    "クエリのトップレベルemail=victim(攻撃者はボディuserで認証)" => lambda { |attacker, ip|
      post "#{SIGN_IN_PATH}?email=#{VICTIM_EMAIL}",
           params: { user: { email: attacker.email, password: KNOWN_PASSWORD } },
           as: :json, headers: { "REMOTE_ADDR" => "10.0.0.1", "Fly-Client-IP" => ip }
    },
    "ボディのトップレベルemail=victim(攻撃者はクエリuser[email]で認証)" => lambda { |attacker, ip|
      post "#{SIGN_IN_PATH}?user[email]=#{attacker.email}&user[password]=#{KNOWN_PASSWORD}",
           params: { email: VICTIM_EMAIL }, as: :json,
           headers: { "REMOTE_ADDR" => "10.0.0.1", "Fly-Client-IP" => ip }
    }
  }.each do |label, attacker_sign_in|
    test "攻撃者の成功ログインに#{label}を混ぜても被害者の失敗カウンタは消えず、被害者は10回目まで通常応答で11回目が429" do
      attacker = create_known_user
      (EMAIL_FAILURE_LIMIT - 1).times do
        post_credentials(email: VICTIM_EMAIL, password: "x", ip: next_ip)
        assert_equal 401, response.status
      end

      instance_exec(attacker, next_ip, &attacker_sign_in)
      assert_equal 200, response.status, "攻撃者の成功ログインが成立していない"
      discard_session_cookie

      post_credentials(email: VICTIM_EMAIL, password: "x", ip: next_ip)
      assert_equal 401, response.status, "10 回目は制限前なので 401 のはず"

      post_credentials(email: VICTIM_EMAIL, password: "x", ip: next_ip)
      assert_equal 429, response.status, "被害者の失敗カウンタが攻撃者の成功で消えた"
    end
  end

  test "存在しないemailへの失敗も数え、10回失敗後は429(ユーザー列挙対策で同じ扱い)" do
    EMAIL_FAILURE_LIMIT.times do |attempt_index|
      post_credentials(email: "nobody@example.com", password: "x", ip: next_ip)
      assert_equal 401, response.status, "#{attempt_index + 1} 回目が 401 でない(#{response.status})"
    end

    post_credentials(email: "nobody@example.com", password: "x", ip: next_ip)
    assert_equal 429, response.status
    assert_equal EMAIL_RETRY_AFTER, response.headers["Retry-After"].to_i
  end

  test "Rack::Attack無効のときは失敗を数えず、その後有効化しても即429にならない" do
    user = create_known_user
    Rack::Attack.enabled = false
    15.times do
      post_credentials(email: user.email, password: "wrong-password", ip: next_ip)
      assert_not_equal 429, response.status
    end

    Rack::Attack.enabled = true
    EMAIL_FAILURE_LIMIT.times do |attempt_index|
      post_credentials(email: user.email, password: "wrong-password", ip: next_ip)
      assert_not_equal 429, response.status, "有効化後 #{attempt_index + 1} 回目で 429(無効時の失敗が数えられた)"
    end
  end

  test "sign_in以外のWarden失敗(JWT無しで認証必須APIを叩く)はemailカウンタを増やさない" do
    20.times do
      get "/api/v1/me?user[email]=victim@example.com&email=victim@example.com",
          headers: { "REMOTE_ADDR" => next_ip }
      assert_equal 401, response.status
    end

    EMAIL_FAILURE_LIMIT.times do |attempt_index|
      post_credentials(email: "victim@example.com", password: "x", ip: next_ip)
      assert_not_equal 429, response.status, "sign_in 以外の失敗が数えられ #{attempt_index + 1} 回目で 429"
    end

    post_credentials(email: "victim@example.com", password: "x", ip: next_ip)
    assert_equal 429, response.status
  end

  private

  # テスト環境では Rails 側の 400 相当(不正JSON)が例外として伝播することがある。
  # それは許容し、rack-attack 層(config/initializers/rack_attack.rb)由来の例外だけを失敗とする。
  # 例外が出たらその例外を、出なかったら nil を返す(前回の response を誤参照させない)。
  def assert_no_rack_attack_failure
    yield
    nil
  rescue StandardError => error
    origin = [ error, error.cause ].compact.flat_map(&:backtrace).compact
    flunk "rack-attack 層で例外: #{error.class}: #{error.message}" if origin.any? { |line| line.include?("rack_attack.rb") }
    error
  end

  # 同一IPで10回叩いても500/rack-attack例外にならず、11回目が429になる(throttle が握り潰されていない)。
  def assert_ip_throttle_survives(ip)
    10.times do |attempt_index|
      raised = assert_no_rack_attack_failure { yield ip }
      assert_not_equal 500, response.status, "#{attempt_index + 1} 回目で 500" if raised.nil?
      assert_not_equal 429, response.status, "#{attempt_index + 1} 回目で 429 になった" if raised.nil?
    end

    raised = assert_no_rack_attack_failure { yield ip }
    assert_nil raised, "11回目は rack-attack が応答するはずが例外になった: #{raised.inspect}"
    assert_equal 429, response.status
  end

  def assert_not_rack_attack_rejection(label)
    return unless response.status == 400

    error_message = (JSON.parse(response.body)["error"] rescue nil)
    japanese = error_message.is_a?(String) && error_message.match?(/\p{Hiragana}|\p{Katakana}|\p{Han}/)
    assert_not japanese, "#{label}: 無効時にrack-attack由来の400になった: #{error_message}"
  end

  def json_headers(ip)
    { "REMOTE_ADDR" => ip, "CONTENT_TYPE" => "application/json" }
  end

  def post_sign_in(email:, ip:)
    post SIGN_IN_PATH,
         params: { user: { email: email, password: "wrong-password" } },
         as: :json,
         headers: { "REMOTE_ADDR" => ip }
  end

  def post_sign_in_via_fly(email:, remote_addr:, fly_client_ip:, forwarded_for: nil)
    headers = { "REMOTE_ADDR" => remote_addr, "Fly-Client-IP" => fly_client_ip }
    headers["X-Forwarded-For"] = forwarded_for if forwarded_for
    post SIGN_IN_PATH, params: { user: { email: email, password: "wrong-password" } }, as: :json, headers: headers
  end

  def create_known_user
    user = User.create!(email: "known-#{SecureRandom.hex(6)}@example.com", password: KNOWN_PASSWORD,
                        display_name: "レート制限テスト")
    @created_users << user
    user
  end

  # IP 単位(10回/分)に当たらないよう毎回別の Fly-Client-IP を使う
  def next_ip
    @ip_sequence = (@ip_sequence || 0) + 1
    "198.18.#{@ip_sequence / 250}.#{@ip_sequence % 250 + 1}"
  end

  # 本番のJWTクライアントはCookieを持たない別クライアント。成功ログイン後のセッションCookieが残ると
  # Deviseのrequire_no_authenticationで「ログイン済み」扱いになり後続の失敗POSTが認証失敗にならないため全Cookieを捨てる(セッション名はconfig/application.rbのmiddleware側で決まる)。
  def discard_session_cookie
    cookies.to_hash.each_key { |cookie_name| cookies.delete(cookie_name) }
  end

  def post_credentials(email:, password:, ip:)
    post SIGN_IN_PATH,
         params: { user: { email: email, password: password } },
         as: :json,
         headers: { "REMOTE_ADDR" => "10.0.0.1", "Fly-Client-IP" => ip }
  end

  def unique_email
    @sequence += 1
    "rate-limit-#{@sequence}@example.com"
  end
end
