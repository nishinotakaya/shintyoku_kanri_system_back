require "net/http"
require "json"
require "uri"

# freee 取引先 (partners) の検索 + 必要なら作成。
# secure.freee.co.jp/api/p/partners を使う (Web フロント内部 API)。
module Freee
  class PartnerLookup
    LIST_URL   = "https://secure.freee.co.jp/api/p/partners"
    CREATE_URL = "https://secure.freee.co.jp/api/p/partners"

    def initialize(connection:, company_id:)
      @conn = connection
      @company_id = company_id.to_s
      @effective_cookie = nil
      @effective_csrf = nil
    end

    # 名前で取引先を探して partner_id を返す。無ければ create=true なら作成する。
    def find_or_create(name:, create: true)
      id = find(name)
      return id if id
      return nil unless create
      refresh_accounting_context!
      create_partner(name)
    end

    # accounting アプリの GET /partners を一度叩いて、cu_cid cookie + 最新 CSRF を取得する。
    # 共通実装は Freee::AccountingContext に切り出し済。
    def refresh_accounting_context!
      ctx = Freee::AccountingContext.new(connection: @conn, company_id: @company_id).refresh!(path: "/partners")
      @effective_cookie = ctx.cookie
      @effective_csrf = ctx.csrf
    end

    def find(name)
      uri = URI(LIST_URL)
      uri.query = URI.encode_www_form(company_id: @company_id, keyword: name, limit: 50)
      res = get(uri)
      return nil unless res.code == "200"
      json = JSON.parse(res.body)
      partners = json["partners"] || json["data"] || []
      hit = partners.find { |p| (p["shown_name"] || p["name"]).to_s.include?(name) }
      hit&.dig("id")&.to_i
    rescue StandardError => e
      Rails.logger.warn("[Freee::PartnerLookup#find] #{e.class}: #{e.message}")
      nil
    end

    def create_partner(name)
      uri = URI(CREATE_URL)
      payload = {
        company_id: @company_id.to_i,
        partner: { name: name, shown_name: name, org_code: 0 }
      }
      res = post(uri, payload)
      return nil unless res.code.start_with?("2")
      JSON.parse(res.body).dig("partner", "id")&.to_i
    rescue StandardError => e
      Rails.logger.warn("[Freee::PartnerLookup#create] #{e.class}: #{e.message}")
      nil
    end

    private

    def get(uri)
      http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true }
      req = Net::HTTP::Get.new(uri.request_uri)
      common_headers(req)
      req["accept"] = "application/json"
      req["x-requested-with"] = "XMLHttpRequest"
      req["x-company-id"] = @company_id
      req["cookie"] = @conn.session_cookie.to_s
      http.request(req)
    end

    def post(uri, payload)
      http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true }
      req = Net::HTTP::Post.new(uri.path)
      common_headers(req)
      req["accept"] = "application/json"
      req["content-type"] = "application/json; charset=UTF-8"
      req["origin"] = "https://secure.freee.co.jp"
      req["referer"] = "https://secure.freee.co.jp/partners"
      req["x-company-id"] = @company_id
      req["x-csrf-token"] = (@effective_csrf || @conn.csrf_token).to_s
      req["x-xhr-from"] = "request-ts"
      req["x-requested-with"] = "XMLHttpRequest"
      req["cookie"] = (@effective_cookie || @conn.session_cookie).to_s
      req.body = payload.to_json
      http.request(req)
    end

    def common_headers(req)
      req["accept-language"] = "ja,en-US;q=0.9,en;q=0.8"
      req["user-agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/148.0.0.0 Safari/537.36"
    end
  end
end
