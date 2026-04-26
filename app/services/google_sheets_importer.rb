require "google/apis/sheets_v4"
require "date"

# Google スプレッドシートから進捗管理データを読み取り、BacklogTask にインポートする。
# 進捗管理_西野.xlsx と同じフォーマットを想定:
# B列: タスク名(SAP-XXXX)、F:予定開始、G:予定終了、H:実績開始、I:実績終了、J:進捗率
class GoogleSheetsImporter
  def initialize(user:, spreadsheet_url:, sheet_name: nil)
    @user = user
    @spreadsheet_id = extract_id(spreadsheet_url)
    @sheet_name = sheet_name
    raise "Google アクセストークンがありません。再度 Google ログインしてください。" unless @user.google_access_token.present?
  end

  def call
    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = build_auth

    # シート一覧取得
    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    sheets = spreadsheet.sheets.map { |s| { title: s.properties.title, id: s.properties.sheet_id } }

    titles = sheets.map { |s| s[:title] }
    # 指定があればそのシートのみ。なければ「現在のタスク」「完了タスク」両方（存在する方）を対象
    targets = if @sheet_name
                [@sheet_name]
              else
                defaults = ["現在のタスク", "完了タスク"] & titles
                defaults.any? ? defaults : [titles.first].compact
              end

    imported = []
    targets.each do |target|
      range = "#{target}!A1:L500"
      rows = (service.get_spreadsheet_values(@spreadsheet_id, range).values || [])
      formula_rows = (service.get_spreadsheet_values(@spreadsheet_id, range, value_render_option: "FORMULA").values || [])
      imported.concat(parse_and_import(rows, formula_rows))
    end
    { imported: imported.size, sheets: titles, tasks: imported }
  end

  def list_sheets
    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = build_auth
    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    spreadsheet.sheets.map { |s| s.properties.title }
  end

  private

  def extract_id(url)
    m = url.match(%r{/spreadsheets/d/([a-zA-Z0-9_-]+)})
    raise "スプレッドシートのURLが不正です" unless m
    m[1]
  end

  def build_auth
    auth = Signet::OAuth2::Client.new(
      token_credential_uri: "https://oauth2.googleapis.com/token",
      client_id: ENV["GOOGLE_CLIENT_ID"],
      client_secret: ENV["GOOGLE_CLIENT_SECRET"],
      access_token: @user.google_access_token,
      refresh_token: @user.google_refresh_token
    )

    # トークン期限切れなら refresh
    if @user.google_token_expires_at && @user.google_token_expires_at < Time.current && @user.google_refresh_token.present?
      auth.fetch_access_token!
      @user.update!(
        google_access_token: auth.access_token,
        google_token_expires_at: Time.current + 3600
      )
    end

    auth
  end

  def parse_and_import(rows, formula_rows = [])
    imported = []

    # 列構成を自動検出（進捗管理_西野.xlsx 形式）
    # B列タイトル → col 1 (0-indexed)、F-I → col 5-8、J → col 9
    # A列タイトル → col 0、E-H → col 4-7、I → col 8
    title_col, plan_s, plan_e, act_s, act_e, prog_col = detect_layout(rows)

    rows.each_with_index do |row, i|
      next if i < 3 # ヘッダ行 + 空行スキップ（セクション見出し【】は下で除外）

      title = row[title_col].to_s.strip
      next if title.empty? || title.start_with?("【") || title.start_with?("[")

      # HYPERLINK 数式から URL とタイトルを抽出
      formula = formula_rows.dig(i, title_col).to_s
      url = nil
      if (m = formula.match(/\AHYPERLINK\("([^"]*)","([^"]*)"\)\z/i) || formula.match(/\A=HYPERLINK\("([^"]*)","([^"]*)"\)\z/i))
        url = m[1]
        title = m[2].to_s.strip if title.empty?
      end

      sap = title.match(/(SAP-\d+)/i)&.captures&.first&.upcase
      actual_start = parse_date(row[act_s])
      actual_end = parse_date(row[act_e])
      plan_start = parse_date(row[plan_s])
      plan_end = parse_date(row[plan_e])
      progress = parse_progress(row[prog_col])

      start = actual_start || plan_start
      next unless start

      key = sap || "SHEET-#{Digest::MD5.hexdigest(title)[0..5].upcase}"

      # A列の id で既存タスクを検索（あれば更新、なければ issue_key で find_or_initialize）
      id_val = title_col == 1 ? row[0].to_s.strip : ""
      task = if id_val.match?(/\A\d+\z/)
               @user.backlog_tasks.find_by(id: id_val.to_i) || @user.backlog_tasks.find_or_initialize_by(issue_key: key)
             else
               @user.backlog_tasks.find_or_initialize_by(issue_key: key)
             end
      task.issue_key ||= key
      task.summary = title[0..80]
      task.created_on = start
      task.due_date = actual_end || plan_end
      task.start_date = start
      task.end_date = actual_end || plan_end
      task.source ||= "sheet"
      task.url = url if url.present?

      if progress
        task.progress_value = progress
        if progress >= 1.0
          task.status_id = 4
          task.status_name = "完了"
          task.completed_on ||= task.end_date || Date.current
        elsif progress >= 0.8
          task.status_id = 3
          task.status_name = "処理済"
        elsif progress > 0
          task.status_id = 2
          task.status_name = "処理中"
        else
          task.status_id = 1
          task.status_name = "未対応"
        end
      else
        task.status_id ||= 1
        task.status_name ||= "未対応"
      end

      task.save!
      imported << task
    end

    imported
  end

  def detect_layout(rows)
    # B列にテキストが多ければ進捗管理_西野.xlsx形式
    b_texts = rows[0..9].count { |r| r[1].to_s.strip.present? }
    a_texts = rows[0..9].count { |r| r[0].to_s.strip.present? }

    if b_texts > a_texts
      [1, 5, 6, 7, 8, 9]  # B列タイトル
    else
      [0, 4, 5, 6, 7, 8]  # A列タイトル
    end
  end

  def parse_date(val)
    return nil if val.nil? || val.to_s.strip.empty?
    Date.parse(val.to_s)
  rescue
    nil
  end

  def parse_progress(val)
    return nil if val.nil? || val.to_s.strip.empty?
    v = val.to_s.strip
    if v.end_with?("%")
      v.to_f / 100.0
    elsif v.to_f <= 1.0 && v.match?(/^[\d.]+$/)
      v.to_f
    else
      nil
    end
  end
end
