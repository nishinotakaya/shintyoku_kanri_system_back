#!/usr/bin/env ruby
# Notion DB から西野鷹也 + 川村のタスクを取得して markdown 表に書き出す

require "net/http"
require "json"
require "uri"

COLLECTION_ID  = "21e123f2-61d2-80ca-a490-000b02914dd5"
COLLECTION_VIEW_ID = "21e123f2-61d2-80b2-9c52-000c51b8b437"
SPACE_ID = "1578478a-5efe-4c45-831c-e8a0bd820fd6"
ACTIVE_USER_ID = "4499436c-d52d-46cc-acc6-6d740ea0e5a0"

OUTPUT_PATH = File.expand_path("../../docs/notion_wbs_nishino_kawamura.md", __dir__)

env = File.read(File.expand_path("../../.env", __dir__))
cookie = env.match(/^NOTION_COOKIE=(.+)$/)&.[](1)&.strip&.delete_prefix("'")&.delete_suffix("'")
abort "NOTION_COOKIE が見つかりません" if cookie.nil? || cookie.empty?

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
abort "HTTP #{response.code}\n#{response.body[0, 500]}" unless response.code == "200"

data = JSON.parse(response.body)
record_map = data["recordMap"] || {}
block_map = record_map["block"] || {}
user_map = record_map["notion_user"] || {}
result_ids = data.dig("result", "reducerResults", "collection_group_results", "blockIds") || []

def user_name(user_map, user_id)
  user = user_map.dig(user_id, "value", "value") || user_map.dig(user_id, "value")
  return user_id unless user
  [ user["name"], user["given_name"], user["family_name"] ].compact.reject(&:empty?).first || user_id
end

def extract_text(prop)
  return "" if prop.nil?
  prop.map { |segment| segment[0] }.join.strip
end

def extract_date(prop)
  return "" if prop.nil?
  prop.each do |segment|
    next unless segment[1]
    segment[1].each do |annotation|
      next unless annotation[0] == "d"
      date = annotation[1]
      start_date = date["start_date"]
      end_date = date["end_date"]
      return end_date ? "#{start_date} → #{end_date}" : start_date
    end
  end
  ""
end

def extract_persons(prop, user_map)
  return "" if prop.nil?
  ids = []
  prop.each do |segment|
    next unless segment[1]
    segment[1].each do |annotation|
      ids << annotation[1] if annotation[0] == "u"
    end
  end
  ids.map { |id| user_name(user_map, id) }.join(", ")
end

rows = result_ids.map do |block_id|
  block = block_map.dig(block_id, "value", "value") || block_map.dig(block_id, "value")
  next nil if block.nil?
  properties = block["properties"] || {}

  wbs_level = extract_text(properties["dgbk"])
  title = extract_text(properties["title"])
  parent_task = extract_text(properties["\\d\\h"])
  assignee = extract_persons(properties["ENlJ"], user_map)
  start_date = extract_date(properties["_St?"])
  end_date = extract_date(properties["tA@]"])
  workload = extract_text(properties["MFfU"])
  progress_rate_raw = extract_text(properties["DH}N"])
  status = extract_text(properties[">|KT"])
  priority = extract_text(properties["SMys"])
  note = extract_text(properties["<jwv"])

  progress_rate = progress_rate_raw.empty? ? "" : "#{(progress_rate_raw.to_f * 100).round}%"

  {
    wbs_level: wbs_level,
    title: title,
    parent_task: parent_task,
    assignee: assignee,
    start_date: start_date,
    end_date: end_date,
    workload: workload,
    progress_rate: progress_rate,
    status: status,
    priority: priority,
    note: note
  }
end.compact

rows.sort_by! { |row| row[:wbs_level].split(".").map { |level| level.to_i.to_s.rjust(4, "0") }.join(".") }

def escape(value)
  value.to_s.gsub("|", "\\|").gsub("\n", " ")
end

header_columns = %w[WBS タスク名 親タスク 担当者 開始日 終了日 工数(人日) 進捗率 進捗状況 優先度 備考]
separator = ([ "---" ] * header_columns.size).join(" | ")

lines = []
lines << "# WBS（フェーズ1：現行機能の刷新） — 西野鷹也 + 川村卓也"
lines << ""
lines << "- 取得元: Notion DB `21e123f261d2802b93bae6e0f9406682`"
lines << "- 取得日: #{Time.now.strftime('%Y-%m-%d %H:%M')}"
lines << "- 件数: #{rows.size}"
lines << ""
lines << "| #{header_columns.join(' | ')} |"
lines << "| #{separator} |"

rows.each do |row|
  cells = [
    row[:wbs_level], row[:title], row[:parent_task], row[:assignee],
    row[:start_date], row[:end_date], row[:workload], row[:progress_rate],
    row[:status], row[:priority], row[:note]
  ].map { |value| escape(value) }
  lines << "| #{cells.join(' | ')} |"
end

require "fileutils"
FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))
File.write(OUTPUT_PATH, lines.join("\n") + "\n")

puts "出力: #{OUTPUT_PATH}"
puts "件数: #{rows.size}"
