require "net/http"
require "json"
require "uri"

# freee accounts へのセッションログイン。
# 公式 OAuth ではなく、Web フロントが使う内部 sessions API を直接叩く。
# 利用上の注意: パスワード変更 / 2FA 有効化 / 利用規約の変更により破綻する可能性あり。
#
# 2 段階フロー:
#   1) GET /sessions/new  → 初期 cookie (XSRF-TOKEN 含む) を取得
#   2) POST /api/p/sessions → 取得した cookie と XSRF を乗せて認証
module Freee
  class SessionLogin
    PRELOGIN_URL = "https://accounts.secure.freee.co.jp/sessions/new?redirect_url=https%3A%2F%2Fsecure.freee.co.jp%2Fusers%2Fafter_login&service_name=accounting&sign_up_url=https%3A%2F%2Fsecure.freee.co.jp%2Fusers%2Fsign_up"
    SESSIONS_URL = "https://accounts.secure.freee.co.jp/api/p/sessions"
    USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

    Result = Struct.new(
      :ok?, :status, :body,
      :session_cookie, :csrf_token, :company_id,
      :error,
      keyword_init: true
    )

    def initialize(identity:, password:)
      @identity = identity
      @password = password
      @cookie_jar = {}  # name => value
    end

    def call
      pre_status, pre_body = prelogin!
      return Result.new(ok?: false, status: pre_status, body: pre_body, error: "prelogin failed") unless pre_status == 200

      csrf = decoded_cookie("XSRF-TOKEN")
      uri = URI(SESSIONS_URL)
      req = Net::HTTP::Post.new(uri.path)
      common_headers(req)
      req["content-type"] = "application/json"
      req["origin"] = "https://accounts.secure.freee.co.jp"
      req["referer"] = PRELOGIN_URL
      req["x-freee-client-name"] = "accounts"
      req["x-requested-with"] = "XMLHttpRequest"
      req["x-csrf-token"] = csrf if csrf
      req["cookie"] = cookie_header
      req.body = {
        identity: @identity,
        password: @password,
        service_name: "accounting",
        redirect_url: "https%3A%2F%2Fsecure.freee.co.jp%2Fusers%2Fafter_login",
        sign_up_url: "https://secure.freee.co.jp/users/sign_up"
      }.to_json

      res = https(uri).request(req)
      merge_cookies(res)

      # 2 段階目: secure.freee.co.jp 側のセッション (cu_cid / accounting CSRF) を取得する。
      # accounts.secure.freee.co.jp のログインだけだと cu_cid (=company_id) が無いため、
      # 売上計上 API (secure.freee.co.jp/api/p/deals/standard) を叩けない。
      after_csrf = nil
      if res.code == "200"
        after_csrf = follow_after_login!
      end

      # cu_cid cookie が無ければ accounting アプリの /api/p/users/me で取得
      company_id = @cookie_jar["cu_cid"] || fetch_company_id

      Result.new(
        ok?: res.code == "200",
        status: res.code.to_i,
        body: res.body,
        session_cookie: cookie_header,
        csrf_token: after_csrf || extract_csrf_token(res) || csrf,
        company_id: company_id
      )
    rescue StandardError => e
      Result.new(ok?: false, status: 0, error: "#{e.class}: #{e.message}")
    end

    # after_login へリダイレクトを辿って secure.freee.co.jp の cookie + CSRF を取得。
    # 戻り値: after_login 側で取れた CSRF トークン（HTML の meta タグから抽出）
    # 注意: cu_cid (company_id) は accounting アプリを開かないと set されないため、
    #       FREEE_COMPANY_ID 環境変数で別途指定するか、FreeeConnection に保存しておく。
    def follow_after_login!
      url = "https://secure.freee.co.jp/users/after_login"
      8.times do
        uri = URI(url)
        req = Net::HTTP::Get.new(uri.request_uri)
        common_headers(req)
        req["accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        req["upgrade-insecure-requests"] = "1"
        req["cookie"] = cookie_header
        res = https(uri).request(req)
        merge_cookies(res)

        if [ "301", "302", "303", "307", "308" ].include?(res.code)
          loc = res["location"]
          break unless loc
          url = loc.start_with?("http") ? loc : "https://#{uri.host}#{loc}"
          next
        end

        # 200 = HTML 取得完了。meta name="csrf-token" content="..." を拾う
        if (m = res.body.to_s.match(/<meta\s+name="csrf-token"\s+content="([^"]+)"/))
          return m[1]
        end
        return nil
      end
      nil
    end

    # secure.freee.co.jp/api/p/users/me を叩いて、ログインユーザーの会社一覧から
    # accounting の company_id を取得する。
    def fetch_company_id
      uri = URI("https://secure.freee.co.jp/api/p/users/me")
      req = Net::HTTP::Get.new(uri.request_uri)
      common_headers(req)
      req["accept"] = "application/json"
      req["x-requested-with"] = "XMLHttpRequest"
      req["cookie"] = cookie_header
      res = https(uri).request(req)
      return nil unless res.code == "200"
      json = JSON.parse(res.body)
      # 形式: { user: { companies: [{ id: ..., display_name: ..., role: ... }] } }
      cs = json.dig("user", "companies") || json["companies"] || []
      first = cs.find { |c| c["accounting_charged"] != false } || cs.first
      first&.dig("id")&.to_s
    rescue StandardError => e
      Rails.logger.warn("[Freee::SessionLogin#fetch_company_id] #{e.class}: #{e.message}")
      nil
    end

    private

    def prelogin!
      uri = URI(PRELOGIN_URL)
      req = Net::HTTP::Get.new(uri.request_uri)
      common_headers(req)
      req["accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      req["upgrade-insecure-requests"] = "1"
      res = https(uri).request(req)
      merge_cookies(res)
      [ res.code.to_i, res.body.to_s.slice(0, 200) ]
    end

    def https(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |h|
        h.use_ssl = true
        h.read_timeout = 15
        h.open_timeout = 10
      end
    end

    def common_headers(req)
      req["accept"] = "application/json, text/plain, */*" unless req["accept"]
      req["accept-language"] = "ja,en-US;q=0.9,en;q=0.8"
      req["user-agent"] = USER_AGENT
    end

    def merge_cookies(res)
      (res.get_fields("set-cookie") || []).each do |raw|
        name_value = raw.split(";").first
        next unless name_value&.include?("=")
        name, value = name_value.split("=", 2)
        @cookie_jar[name.strip] = value.strip
      end
    end

    def cookie_header
      @cookie_jar.map { |k, v| "#{k}=#{v}" }.join("; ")
    end

    # XSRF-TOKEN は URL-encoded で cookie に入っているので decode する。
    def decoded_cookie(name)
      v = @cookie_jar[name]
      v ? URI.decode_www_form_component(v) : nil
    end

    def extract_csrf_token(res)
      JSON.parse(res.body)["csrf_token"]
    rescue StandardError
      nil
    end
  end
end
