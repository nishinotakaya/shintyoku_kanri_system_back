# Notion「ドキュメントハブ」DB から資料の URL（ファイル&メディア）を取得し、
# 対応ログの備考（BacklogSummaryNote）へ「資料:カテゴリ」行としてまとめて保存する。
#   ・OneDrive 等の外部 URL はそのまま
#   ・Notion 添付ファイル(attachment:)は行の Notion ページ URL に変換（ブラウザでログイン済みなら開ける）
#   ・カテゴリ（受領資料/要件定義/基本設計…）ごとに 1 行、当月の月次サマリに出る
class NotionDocHubImporter
  COLLECTION_ID = "1a6123f2-61d2-8054-9af5-000b605a9403".freeze
  VIEW_ID       = "1a6123f2-61d2-80f0-aa81-000ceafc6288".freeze
  PROP_FILES    = "RcSe".freeze # ファイル&メディア
  PROP_CATEGORY = "zhsM".freeze # カテゴリー

  def initialize(user)
    @user = user
  end

  def call
    month = Time.zone.today.strftime("%Y-%m")
    grouped = documents.group_by { |doc| doc[:category].presence || "その他" }
    grouped.map do |category, docs|
      lines = docs.flat_map { |doc| doc[:links].map { |url| "#{doc[:title]}: #{url}" } }
      note = @user.backlog_summary_notes.find_or_initialize_by(month: month, issue_key: "資料:#{category}")
      note.note = lines.join("\n")
      note.save!
      { category: category, documents: docs.size, links: lines.size }
    end
  end

  private

  def documents
    data = NotionClient.new.query_collection(collection_id: COLLECTION_ID, view_id: VIEW_ID)
    block_ids = data.dig("result", "reducerResults", "collection_group_results", "blockIds") || []
    blocks = data.dig("recordMap", "block") || {}

    block_ids.filter_map do |block_id|
      block = blocks.dig(block_id, "value")
      block = block["value"] if block && block["value"].is_a?(Hash)
      next unless block
      properties = block["properties"] || {}
      title = (properties["title"] || []).map { |segment| segment[0] }.join.strip
      next if title.blank?
      links = extract_links(properties[PROP_FILES], block_id)
      next if links.empty?
      {
        title: title,
        category: (properties[PROP_CATEGORY] || []).map { |segment| segment[0] }.join.strip,
        links: links
      }
    end
  end

  # ファイル&メディア property から URL を取り出す。
  # 外部 URL はそのまま、Notion 添付(attachment:)は行ページの URL 1 つに集約する。
  def extract_links(file_property, block_id)
    urls = []
    has_attachment = false
    Array(file_property).each do |segment|
      Array(segment[1]).flatten.grep(String).each do |value|
        if value.start_with?("http")
          urls << value
        elsif value.start_with?("attachment:")
          has_attachment = true
        end
      end
    end
    urls << notion_page_url(block_id) if has_attachment
    urls.uniq
  end

  def notion_page_url(block_id)
    "https://www.notion.so/#{block_id.delete('-')}"
  end
end
