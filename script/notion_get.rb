#!/usr/bin/env ruby
# Notion 内部 API でゲストワークスペースの DB を読み取る
#
# 使い方:
#   cd rails-backend
#   ruby script/notion_get.rb
#
# .env から NOTION_COOKIE を読む（ブラウザ DevTools から token_v2 を含む Cookie ヘッダをコピペ）

require "net/http"
require "json"
require "uri"

COLLECTION_ID  = "21e123f2-61d2-80ca-a490-000b02914dd5"
COLLECTION_VIEW_ID = "21e123f2-61d2-80b2-9c52-000c51b8b437"
SPACE_ID = "1578478a-5efe-4c45-831c-e8a0bd820fd6"
ACTIVE_USER_ID = "4499436c-d52d-46cc-acc6-6d740ea0e5a0"

ASSIGNEE_PROPERTY = "ENlJ"
ASSIGNEE_USER_IDS = [
  "4499436c-d52d-46cc-acc6-6d740ea0e5a0",  # 西野鷹也
  "e1c39454-24a8-4955-a538-58e0430f97b6"   # 川村さん
]

env_path = File.expand_path("../../.env", __dir__)
env = File.read(env_path)
cookie = env.match(/^NOTION_COOKIE=(.+)$/)&.[](1)&.strip&.delete_prefix("'")&.delete_suffix("'")
abort "NOTION_COOKIE が .env にありません" if cookie.nil? || cookie.empty?

uri = URI("https://www.notion.so/api/v3/queryCollection?src=initial_load")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true

request = Net::HTTP::Post.new(uri)
request["accept"] = "*/*"
request["content-type"] = "application/json"
request["cookie"] = cookie
request["origin"] = "https://www.notion.so"
request["referer"] = "https://www.notion.so/#{COLLECTION_VIEW_ID.delete('-')}"
request["user-agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
request["x-notion-active-user-header"] = ACTIVE_USER_ID
request["x-notion-space-id"] = SPACE_ID

request.body = {
  clientType: "notion_app",
  source: { type: "collection", id: COLLECTION_ID, spaceId: SPACE_ID },
  collectionView: { id: COLLECTION_VIEW_ID, spaceId: SPACE_ID },
  loader: {
    reducers: { collection_group_results: { type: "results", limit: 200 } },
    filter: {
      operator: "and",
      filters: [{
        property: ASSIGNEE_PROPERTY,
        filter: {
          operator: "person_contains",
          value: ASSIGNEE_USER_IDS.map { |id| { type: "exact", value: { table: "notion_user", id: id } } }
        }
      }]
    },
    sort: [],
    searchQuery: "",
    archiveStatus: "NON_ARCHIVED",
    userId: ACTIVE_USER_ID,
    userTimeZone: "Asia/Tokyo"
  }
}.to_json

response = http.request(request)

unless response.code == "200"
  warn "HTTP #{response.code}"
  warn response.body[0, 1000]
  exit 1
end

data = JSON.parse(response.body)
record_map = data.dig("recordMap", "block") || {}
result_block_ids = data.dig("result", "reducerResults", "collection_group_results", "blockIds") || []

puts "取得件数: #{result_block_ids.size}"
puts "----"

result_block_ids.each_with_index do |block_id, index|
  block = record_map.dig(block_id, "value", "value") || record_map.dig(block_id, "value")
  next if block.nil?
  properties = block["properties"] || {}
  title = (properties["title"] || []).flatten.compact.join
  puts "#{index + 1}. #{title}"
  puts "   id: #{block_id}"
end
