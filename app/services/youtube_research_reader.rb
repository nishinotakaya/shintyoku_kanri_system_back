require "google/apis/sheets_v4"
require "googleauth"
require "base64"
require "json"
require "stringio"

# onclass のリサーチ用 Google スプレッドシート（自チャンネル + 競合の
# タイトル/再生数/コメント）を読み取り、AI プロンプトに差し込む「高再生の傾向」
# サマリを組み立てる。
#
# データ源: onclass が書き込んでいる同じシートを、onclass のサービスアカウントで
# read-only 流用する（勤怠アプリ側の個人 OAuth トークンの共有設定に依存しない）。
#   ENV["ONCLASS_YOUTUBE_SA_JSON_BASE64"] : onclass サービスアカウント鍵(JSON)の base64
#   ENV["ONCLASS_YOUTUBE_RESEARCH_SPREADSHEET_ID"] : 省略時は既定の onclass シート
class YoutubeResearchReader
  DEFAULT_SPREADSHEET_ID = "1hODzl2TYkFZCRi7GOhkF5XbQgU0a__Tun8LYdegIaBk".freeze
  SELF_SHEET_NAME        = "YouTube".freeze       # 自チャンネル(プロアカ)
  COMPETITOR_SHEET_NAME  = "YouTube競合".freeze   # IT/エンジニア系 競合

  # 先頭3行はメタ(空行 / バッチ実行日時 / ヘッダー)なので実データは4行目から
  DATA_START_ROW = 4

  CACHE_KEY = "youtube_research_summary_v1".freeze
  CACHE_TTL = 12.hours

  TOP_SELF_TITLES       = 15
  TOP_COMPETITOR_TITLES = 20
  TOP_COMMENT_VIDEOS     = 6   # コメントを拾う自チャンネル動画数(上位)
  COMMENTS_PER_VIDEO     = 2

  # キャッシュ付きサマリ。取得できなければ nil（呼び出し側でブロックごと省略する）。
  def self.cached_summary
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { new.summary_text }
  rescue => e
    Rails.logger.warn("[YoutubeResearchReader] cached_summary 失敗: #{e.class} #{e.message}")
    nil
  end

  def summary_text
    self_videos       = fetch_self_videos
    competitor_videos = fetch_competitor_videos
    return nil if self_videos.empty? && competitor_videos.empty?

    sections = []

    if self_videos.any?
      top = self_videos.sort_by { |v| -v[:views] }.first(TOP_SELF_TITLES)
      lines = top.map { |v| "・#{v[:title]}（#{v[:views]}回 / 高評価#{v[:likes]}）" }
      sections << "【自チャンネル(プロアカ/AIプログラマ養成)で再生数が高い動画タイトル（再生数順）】\n#{lines.join("\n")}"

      comments = representative_comments(self_videos)
      if comments.any?
        sections << "【視聴者コメントに多い反応（上位動画より抜粋・視聴者が使う言葉の参考）】\n#{comments.map { |c| "・#{c}" }.join("\n")}"
      end
    end

    if competitor_videos.any?
      top = competitor_videos.sort_by { |v| -v[:views] }.first(TOP_COMPETITOR_TITLES)
      lines = top.map { |v| "・[#{v[:channel]}] #{v[:title]}（#{v[:views]}回）" }
      sections << "【IT/エンジニア系 競合チャンネルで伸びている動画タイトル（再生数順）】\n#{lines.join("\n")}"
    end

    sections.join("\n\n")
  end

  private

  # 自チャンネルタブ: A=サムネ B=タイトル C=出演者 D=公開日 E=視聴回数 F=高評価 G=URL H〜=コメント
  def fetch_self_videos
    rows_for(SELF_SHEET_NAME).filter_map do |row|
      title = row[1].to_s.strip
      next if title.empty?
      {
        title:    title,
        views:    row[4].to_s.gsub(/[^0-9]/, "").to_i,
        likes:    row[5].to_s.gsub(/[^0-9]/, "").to_i,
        comments: row[7..].to_a.map { |c| c.to_s.strip }.reject(&:empty?)
      }
    end
  end

  # 競合タブ: A=サムネ B=チャンネル名 C=タイトル D=公開日 E=視聴回数 F=高評価 G〜=コメント
  def fetch_competitor_videos
    rows_for(COMPETITOR_SHEET_NAME).filter_map do |row|
      title   = row[2].to_s.strip
      channel = row[1].to_s.strip
      next if title.empty?
      {
        channel: channel.presence || "競合",
        title:   title,
        views:   row[4].to_s.gsub(/[^0-9]/, "").to_i
      }
    end
  end

  # 上位動画からコメントを少数ずつ拾い、視聴者の生の言葉を集める（1件120字に丸め）。
  def representative_comments(self_videos)
    self_videos
      .sort_by { |v| -v[:views] }
      .first(TOP_COMMENT_VIDEOS)
      .flat_map { |v| v[:comments].first(COMMENTS_PER_VIDEO) }
      .map { |c| c.gsub(/\s+/, " ").strip.slice(0, 120) }
      .reject(&:empty?)
      .uniq
      .first(10)
  end

  def rows_for(sheet_name)
    range = "#{sheet_name}!A#{DATA_START_ROW}:AA"
    (sheets_service.get_spreadsheet_values(spreadsheet_id, range).values || [])
  rescue Google::Apis::ClientError => e
    Rails.logger.warn("[YoutubeResearchReader] #{sheet_name} 読取失敗: #{e.message}")
    []
  end

  def spreadsheet_id
    ENV["ONCLASS_YOUTUBE_RESEARCH_SPREADSHEET_ID"].presence || DEFAULT_SPREADSHEET_ID
  end

  def sheets_service
    @sheets_service ||= begin
      service = Google::Apis::SheetsV4::SheetsService.new
      service.authorization = onclass_sa_authorizer
      service
    end
  end

  def onclass_sa_authorizer
    b64 = ENV["ONCLASS_YOUTUBE_SA_JSON_BASE64"]
    raise "ENV ONCLASS_YOUTUBE_SA_JSON_BASE64 が未設定です" if b64.blank?

    json = Base64.decode64(b64)
    authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(json),
      scope: ["https://www.googleapis.com/auth/spreadsheets.readonly"]
    )
    authorizer.fetch_access_token!
    authorizer
  end
end
