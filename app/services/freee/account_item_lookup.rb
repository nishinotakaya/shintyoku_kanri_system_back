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

    # 勘定科目名で account_item_id を探す。完全一致 → 前方一致 → 相互部分一致の順。
    # 相互部分一致は「接待交際費」(アプリ側)を freee の「交際費」に名寄せするため
    # (どちらかがどちらかを含めばヒット。複数候補は名前が長い=より具体的なものを優先)。
    # 見つからなければ nil。
    def find(name:)
      target = name.to_s
      return nil if target.blank?

      exact = account_items.find { |item| item_name(item) == target }
      return exact["id"].to_i if exact

      prefix = account_items.find { |item| item_name(item).start_with?(target) || target.start_with?(item_name(item)) }
      return prefix["id"].to_i if prefix

      contains_candidates = account_items.select { |item|
        freee_name = item_name(item)
        freee_name.present? && (freee_name.include?(target) || target.include?(freee_name))
      }
      contains_candidates.max_by { |item| item_name(item).length }&.dig("id")&.to_i
    rescue StandardError => e
      Rails.logger.warn("[Freee::AccountItemLookup#find] #{e.class}: #{e.message}")
      nil
    end

    # 探して無ければ freee に勘定科目を新規作成して id を返す(西野さん指示: 無かったら登録)。
    # 作成時の分類は「雑費」と同じ経費カテゴリを流用する。作成失敗は nil(呼び元で failed 扱い)。
    def find_or_create(name:)
      found = find(name: name)
      return found if found

      create(name: name.to_s)
    end

    private

    def create(name)
      return nil if name.blank?
      template = account_items.find { |item| item_name(item) == "雑費" } || account_items.last
      payload = {
        company_id: @company_id.to_i,
        account_item: {
          name: name,
          categories: template&.dig("categories") || [ "資本", "差引損益計算", "営業損益", "経費" ]
        }
      }
      res = post(URI(LIST_URL), payload)
      unless res.code.start_with?("2")
        Rails.logger.warn("[Freee::AccountItemLookup#create] #{res.code}: #{res.body.to_s[0, 200]}")
        return nil
      end
      created = JSON.parse(res.body)
      @account_items = nil # 次回 find でリストを取り直す
      (created.dig("account_item", "id") || created["id"])&.to_i
    rescue StandardError => e
      Rails.logger.warn("[Freee::AccountItemLookup#create] #{e.class}: #{e.message}")
      nil
    end

    def post(uri, payload)
      http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true }
      req = Net::HTTP::Post.new(uri.path)
      req["accept"] = "application/json"
      req["accept-language"] = "ja,en-US;q=0.9,en;q=0.8"
      req["user-agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/148.0.0.0 Safari/537.36"
      req["content-type"] = "application/json; charset=UTF-8"
      req["origin"] = "https://secure.freee.co.jp"
      req["referer"] = "https://secure.freee.co.jp/account_items"
      req["x-company-id"] = @company_id
      req["x-csrf-token"] = @conn.csrf_token.to_s
      req["x-xhr-from"] = "request-ts"
      req["x-requested-with"] = "XMLHttpRequest"
      req["cookie"] = @conn.session_cookie.to_s
      req.body = payload.to_json
      http.request(req)
    end

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
