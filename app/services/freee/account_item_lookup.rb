require "net/http"
require "json"
require "uri"

# freee 勘定科目 (account_items) の名前 → account_item_id 解決。
# secure.freee.co.jp/api/p/account_items を使う (Web フロント内部 API、PartnerLookup と同じ流儀)。
module Freee
  class AccountItemLookup
    LIST_URL = "https://secure.freee.co.jp/api/p/account_items"

    def initialize(connection:, company_id:)
      @conn = connection
      @company_id = company_id.to_s
    end

    # 勘定科目名で account_item_id を探す。完全一致を優先し、無ければ前方一致(どちらかがどちらかを含む形の名寄せ)。
    # 見つからなければ nil。
    def find(name:)
      target = name.to_s
      return nil if target.blank?

      exact = account_items.find { |item| item_name(item) == target }
      return exact["id"].to_i if exact

      partial = account_items.find { |item| item_name(item).start_with?(target) || target.start_with?(item_name(item)) }
      partial&.dig("id")&.to_i
    rescue StandardError => e
      Rails.logger.warn("[Freee::AccountItemLookup#find] #{e.class}: #{e.message}")
      nil
    end

    private

    # 勘定科目一覧は1回のGETだけ叩いてメモ化する(選択した経費が複数あっても呼び出しは1回)。
    def account_items
      @account_items ||= begin
        uri = URI(LIST_URL)
        uri.query = URI.encode_www_form(company_id: @company_id)
        res = get(uri)
        return [] unless res.code == "200"
        json = JSON.parse(res.body)
        json["account_items"] || json["data"] || []
      end
    end

    def item_name(item)
      (item["name"] || item["display_name"]).to_s
    end

    def get(uri)
      http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true }
      req = Net::HTTP::Get.new(uri.request_uri)
      req["accept"] = "application/json"
      req["accept-language"] = "ja,en-US;q=0.9,en;q=0.8"
      req["user-agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/148.0.0.0 Safari/537.36"
      req["x-requested-with"] = "XMLHttpRequest"
      req["x-company-id"] = @company_id
      req["cookie"] = @conn.session_cookie.to_s
      http.request(req)
    end
  end
end
