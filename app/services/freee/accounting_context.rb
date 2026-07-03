require "net/http"
require "uri"

# accounting アプリ (secure.freee.co.jp) のセッションコンテキストを取得するヘルパ。
# 任意の HTML ページ (例: /deals/standards, /partners) を一度 GET して
# - cu_cid cookie を追加した cookie ヘッダ
# - HTML <meta name="csrf-token"> から取得した最新 CSRF トークン
# を保持する。`Freee::ReportSale` / `Freee::PartnerLookup` の両方から利用される。
module Freee
  class AccountingContext
    USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36".freeze

    attr_reader :cookie, :csrf

    def initialize(connection:, company_id:)
      @conn = connection
      @company_id = company_id.to_s
      @cookie = nil
      @csrf = nil
    end

    # 取引一覧 (/deals/standards) を取って context を確立する。
    # path は省略可 (任意の accounting 配下のページに変更可能)。
    def refresh!(path: "/deals/standards")
      uri = URI("https://secure.freee.co.jp#{path}?company_id=#{@company_id}")
      http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 20 }
      req = Net::HTTP::Get.new(uri.request_uri)
      req["accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      req["accept-language"] = "ja,en-US;q=0.9,en;q=0.8"
      req["user-agent"] = USER_AGENT
      req["cookie"] = @conn.session_cookie.to_s
      res = http.request(req)

      @cookie = merged_cookie_from(res)
      @csrf = extract_csrf(res) || @conn.csrf_token
      self
    end

    private

    def merged_cookie_from(res)
      additional = (res.get_fields("set-cookie") || []).filter_map do |raw|
        nv = raw.split(";").first
        nv if nv && nv.include?("=")
      end
      [ @conn.session_cookie.to_s, *additional, "cu_cid=#{@company_id}" ].compact.reject(&:empty?).join("; ")
    end

    def extract_csrf(res)
      m = res.body.to_s.match(/<meta\s+name="csrf-token"\s+content="([^"]+)"/)
      m ? m[1] : nil
    end
  end
end
