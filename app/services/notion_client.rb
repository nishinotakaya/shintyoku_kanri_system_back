require "net/http"
require "json"
require "uri"

class NotionClient
  COLLECTION_ID      = "21e123f2-61d2-80ca-a490-000b02914dd5"
  COLLECTION_VIEW_ID = "21e123f2-61d2-80b2-9c52-000c51b8b437"
  SPACE_ID           = "1578478a-5efe-4c45-831c-e8a0bd820fd6"
  ACTIVE_USER_ID     = "4499436c-d52d-46cc-acc6-6d740ea0e5a0"

  ASSIGNEE_USER_IDS = [
    "4499436c-d52d-46cc-acc6-6d740ea0e5a0",  # 西野鷹也
    "e1c39454-24a8-4955-a538-58e0430f97b6"   # 川村卓也
  ].freeze

  PROPERTY_IDS = {
    title:         "title",
    wbs_level:     "dgbk",
    parent_task:   "\\d\\h",
    assignee:      "ENlJ",
    start_date:    "_St?",
    end_date:      "tA@]",
    workload:      "MFfU",
    progress_rate: "DH}N",
    status:        ">|KT",
    priority:      "SMys",
    note:          "<jwv"
  }.freeze

  class AuthError < StandardError; end
  class ApiError  < StandardError; end

  def initialize(cookie: ENV["NOTION_COOKIE"])
    raise AuthError, "NOTION_COOKIE 未設定" if cookie.to_s.strip.empty?
    @cookie = cookie
  end

  def query_assigned_tasks
    uri = URI("https://www.notion.so/api/v3/queryCollection?src=initial_load")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["accept"] = "*/*"
    request["content-type"] = "application/json"
    request["cookie"] = @cookie
    request["origin"] = "https://www.notion.so"
    request["user-agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    request["x-notion-active-user-header"] = ACTIVE_USER_ID
    request["x-notion-space-id"] = SPACE_ID
    request.body = build_body.to_json

    response = http.request(request)
    case response.code
    when "200"
      JSON.parse(response.body)
    when "401", "403"
      raise AuthError, "Notion 認証失敗 (HTTP #{response.code})。token_v2 を更新してください"
    else
      raise ApiError, "Notion API エラー HTTP #{response.code}: #{response.body[0, 300]}"
    end
  end

  private

  def build_body
    {
      clientType: "notion_app",
      source: { type: "collection", id: COLLECTION_ID, spaceId: SPACE_ID },
      collectionView: { id: COLLECTION_VIEW_ID, spaceId: SPACE_ID },
      loader: {
        reducers: { collection_group_results: { type: "results", limit: 500 } },
        filter: {
          operator: "and",
          filters: [ {
            property: PROPERTY_IDS[:assignee],
            filter: {
              operator: "person_contains",
              value: ASSIGNEE_USER_IDS.map { |id|
                { type: "exact", value: { table: "notion_user", id: id } }
              }
            }
          } ]
        },
        sort: [],
        searchQuery: "",
        archiveStatus: "NON_ARCHIVED",
        userId: ACTIVE_USER_ID,
        userTimeZone: "Asia/Tokyo"
      }
    }
  end
end
