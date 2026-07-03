#!/usr/bin/env ruby
# プロパティ schema と1件分のサンプルを出すだけのデバッグスクリプト

require "net/http"
require "json"
require "uri"

COLLECTION_ID  = "21e123f2-61d2-80ca-a490-000b02914dd5"
COLLECTION_VIEW_ID = "21e123f2-61d2-80b2-9c52-000c51b8b437"
SPACE_ID = "1578478a-5efe-4c45-831c-e8a0bd820fd6"
ACTIVE_USER_ID = "4499436c-d52d-46cc-acc6-6d740ea0e5a0"

env = File.read(File.expand_path("../../.env", __dir__))
cookie = env.match(/^NOTION_COOKIE=(.+)$/)&.[](1)&.strip&.delete_prefix("'")&.delete_suffix("'")

uri = URI("https://www.notion.so/api/v3/queryCollection?src=initial_load")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true

request = Net::HTTP::Post.new(uri)
request["accept"] = "*/*"
request["content-type"] = "application/json"
request["cookie"] = cookie
request["origin"] = "https://www.notion.so"
request["user-agent"] = "Mozilla/5.0"
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
      filters: [ {
        property: "ENlJ",
        filter: {
          operator: "person_contains",
          value: [
            { type: "exact", value: { table: "notion_user", id: "4499436c-d52d-46cc-acc6-6d740ea0e5a0" } },
            { type: "exact", value: { table: "notion_user", id: "e1c39454-24a8-4955-a538-58e0430f97b6" } }
          ]
        }
      } ]
    },
    sort: [], searchQuery: "", archiveStatus: "NON_ARCHIVED",
    userId: ACTIVE_USER_ID, userTimeZone: "Asia/Tokyo"
  }
}.to_json

response = http.request(request)
data = JSON.parse(response.body)

collection_map = data.dig("recordMap", "collection") || {}
collection = collection_map.values.first
schema = collection.dig("value", "value", "schema") || collection.dig("value", "schema")

puts "=== schema (property_id => name/type) ==="
schema.each do |id, definition|
  puts "  #{id}\t#{definition['type']}\t#{definition['name']}"
end
puts

block_map = data.dig("recordMap", "block") || {}
result_ids = data.dig("result", "reducerResults", "collection_group_results", "blockIds") || []
sample = block_map.dig(result_ids.first, "value", "value") || block_map.dig(result_ids.first, "value")

puts "=== sample block properties (1件目) ==="
puts JSON.pretty_generate(sample["properties"])

puts
puts "=== notion_user record map ==="
(data.dig("recordMap", "notion_user") || {}).each do |id, user|
  v = user.dig("value", "value") || user["value"]
  puts "  #{id}\t#{v['name']}"
end
