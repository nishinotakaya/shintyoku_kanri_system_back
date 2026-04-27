require "google/apis/sheets_v4"

# BacklogTask → Google スプレッドシートに書き出す。
# 進捗管理_西野.xlsx テンプレート準拠。
# シート1: 現在のタスク（処理済→処理中→未対応）
# シート2: 完了タスク
class GoogleSheetsExporter
  # 色定義 (RGB 0-1)
  COLORS = {
    header_bg:    { red: 0.76, green: 0.76, blue: 0.9 },   # 紫ヘッダ
    section_done: { red: 0.6, green: 0.88, blue: 0.6 },    # 緑（処理済）
    section_wip:  { red: 0.6, green: 0.8, blue: 1.0 },     # 青（処理中）
    section_todo: { red: 1.0, green: 0.88, blue: 0.55 },   # オレンジ（未対応）
    completed:    { red: 0.5, green: 0.85, blue: 0.5 },    # 濃い緑（完了）
    white:        { red: 1.0, green: 1.0, blue: 1.0 }
  }.freeze

  def initialize(user:, spreadsheet_url:)
    @user = user
    @spreadsheet_id = extract_id(spreadsheet_url)
    raise "Google アクセストークンがありません。再度 Google ログインしてください。" unless @user.google_access_token.present?
  end

  def call
    @service = Google::Apis::SheetsV4::SheetsService.new
    @service.authorization = build_auth

    spreadsheet = @service.get_spreadsheet(@spreadsheet_id)
    existing = spreadsheet.sheets.map { |s| s.properties.title }

    active_sheet = "現在のタスク"
    completed_sheet = "完了タスク"

    # シートがなければ作成
    ensure_sheet(existing, active_sheet)
    ensure_sheet(existing, completed_sheet)

    # データ取得
    done_tasks = @user.backlog_tasks.where(status_id: 3).order(:issue_key)    # 処理済
    wip_tasks = @user.backlog_tasks.where(status_id: 2).order(:issue_key)     # 処理中
    todo_tasks = @user.backlog_tasks.where(status_id: 1).order(:issue_key)    # 未対応
    completed_tasks = @user.backlog_tasks.where(status_id: 4).order(completed_on: :desc) # 完了

    # シート1: 現在のタスク
    write_active_sheet(active_sheet, done_tasks, wip_tasks, todo_tasks)

    # シート2: 完了タスク
    write_completed_sheet(completed_sheet, completed_tasks)

    { active: done_tasks.size + wip_tasks.size + todo_tasks.size, completed: completed_tasks.size }
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
    if @user.google_token_expires_at && @user.google_token_expires_at < Time.current && @user.google_refresh_token.present?
      auth.fetch_access_token!
      @user.update!(google_access_token: auth.access_token, google_token_expires_at: Time.current + 3600)
    end
    auth
  end

  def ensure_sheet(existing, title)
    return if existing.include?(title)
    req = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(
      requests: [ { add_sheet: { properties: { title: title } } } ]
    )
    @service.batch_update_spreadsheet(@spreadsheet_id, req)
  end

  def write_active_sheet(sheet_name, done_tasks, wip_tasks, todo_tasks)
    rows = []

    # ヘッダ
    rows << [ "", "タスク名", "予定開始", "予定終了", "実績開始", "実績終了", "進捗率", "担当", "備考" ]
    rows << [ "", "", "", "", "", "", "20%=調査中\n40%=実装中\n60%=実装完了\n80%=エビデンス完了\n100%=完了", "", "" ]
    rows << []

    section_rows = [] # セクション行の位置を記録 [row_index, color_key]

    # 完了2日以内セクション（最近完了したもの）
    recent = @user.backlog_tasks.where(status_id: 4)
      .where("completed_on >= ?", Date.current - 2).order(completed_on: :desc)
    if recent.any?
      section_rows << [ rows.size, :completed ]
      rows << [ "", "【完了（2日以内）】" ]
      recent.each { |t| rows << task_row(t) }
      rows << []
    end

    # 処理済セクション
    if done_tasks.any?
      section_rows << [ rows.size, :section_done ]
      rows << [ "", "【処理済】" ]
      done_tasks.each { |t| rows << task_row(t) }
      rows << []
    end

    # 処理中セクション
    if wip_tasks.any?
      section_rows << [ rows.size, :section_wip ]
      rows << [ "", "【処理中】" ]
      wip_tasks.each { |t| rows << task_row(t) }
      rows << []
    end

    # 未対応セクション
    if todo_tasks.any?
      section_rows << [ rows.size, :section_todo ]
      rows << [ "", "【未対応】" ]
      todo_tasks.each { |t| rows << task_row(t) }
      rows << []
    end

    write_and_format(sheet_name, rows, section_rows)
  end

  def write_completed_sheet(sheet_name, tasks)
    rows = []
    rows << [ "", "タスク名", "予定開始", "予定終了", "実績開始", "実績終了", "進捗率", "担当", "備考" ]
    rows << [ "", "", "", "", "", "", "20%=調査中\n40%=実装中\n60%=実装完了\n80%=エビデンス完了\n100%=完了", "", "" ]
    rows << []

    section_rows = [ [ rows.size, :completed ] ]
    rows << [ "", "【完了】" ]
    tasks.each { |t| rows << task_row(t) }

    write_and_format(sheet_name, rows, section_rows)
  end

  def task_row(t)
    progress = t.progress_value || t.progress
    progress_str = progress ? (progress * 100).round.to_s + "%" : ""

    title = "#{t.issue_key} #{t.summary}"
    title_cell = t.url.present? ? %(=HYPERLINK("#{t.url.to_s.gsub('"', '""')}","#{title.gsub('"', '""')}")) : title

    [
      t.id.to_s,                                  # A: id（背景色で非表示）
      title_cell,                                 # B: タスク名
      t.start_date&.to_s || t.created_on&.to_s,  # C: 予定開始
      t.end_date&.to_s || t.due_date&.to_s,      # D: 予定終了
      t.created_on&.to_s,                         # E: 実績開始
      t.completed_on&.to_s,                       # F: 実績終了
      progress_str,                               # G: 進捗率
      t.assignee_name.to_s,                       # H: 担当
      t.memo.to_s                                 # I: 備考
    ]
  end

  def write_and_format(sheet_name, rows, section_rows)
    # クリア
    @service.clear_values(@spreadsheet_id, "#{sheet_name}!A:I")

    # 書き込み
    range = "#{sheet_name}!A1:I#{rows.size}"
    value_range = Google::Apis::SheetsV4::ValueRange.new(range: range, values: rows)
    @service.update_spreadsheet_value(@spreadsheet_id, range, value_range, value_input_option: "USER_ENTERED")

    # シートIDを取得
    spreadsheet = @service.get_spreadsheet(@spreadsheet_id)
    sheet = spreadsheet.sheets.find { |s| s.properties.title == sheet_name }
    return unless sheet
    sheet_id = sheet.properties.sheet_id

    # 書式リクエスト
    requests = []

    # ヘッダ行に背景色
    requests << format_rows(sheet_id, 0, 2, COLORS[:header_bg], true)

    # 既存フィルタをクリア
    if sheet.basic_filter
      requests << { clear_basic_filter: { sheet_id: sheet_id } }
    end

    # セクション行 + その中のタスク行にも背景色
    section_ranges = []
    section_rows.each_with_index do |(row_idx, color_key), i|
      # セクション行自体は太字
      requests << format_rows(sheet_id, row_idx, row_idx + 1, COLORS[color_key], true)

      # 次のセクションまで or 末尾まで、タスク行にも薄い背景色
      next_start = (i + 1 < section_rows.size) ? section_rows[i + 1][0] : rows.size
      if next_start > row_idx + 1
        light_color = {
          red: [ COLORS[color_key][:red] * 0.3 + 0.7, 1.0 ].min,
          green: [ COLORS[color_key][:green] * 0.3 + 0.7, 1.0 ].min,
          blue: [ COLORS[color_key][:blue] * 0.3 + 0.7, 1.0 ].min
        }
        requests << format_rows(sheet_id, row_idx + 1, next_start, light_color, false)
        # A列のidを非表示（文字色=背景色）
        requests << {
          repeat_cell: {
            range: {
              sheet_id: sheet_id,
              start_row_index: row_idx + 1,
              end_row_index: next_start,
              start_column_index: 0,
              end_column_index: 1
            },
            cell: { user_entered_format: { background_color: light_color, text_format: { foreground_color: light_color } } },
            fields: "userEnteredFormat(backgroundColor,textFormat)"
          }
        }
      end
    end

    # B列の幅を広げる
    requests << {
      update_dimension_properties: {
        range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: 1, end_index: 2 },
        properties: { pixel_size: 400 },
        fields: "pixelSize"
      }
    }

    # I列(備考)の幅
    requests << {
      update_dimension_properties: {
        range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: 8, end_index: 9 },
        properties: { pixel_size: 300 },
        fields: "pixelSize"
      }
    }

    if requests.any?
      batch = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests)
      @service.batch_update_spreadsheet(@spreadsheet_id, batch)
    end

    # フィルタを別 batch で設定（結合セルがあるとエラーになるため先に結合解除）
    filter_requests = []
    # 結合を全解除
    spreadsheet = @service.get_spreadsheet(@spreadsheet_id)
    sheet = spreadsheet.sheets.find { |s| s.properties.sheet_id == sheet_id }
    (sheet&.merges || []).each do |merge|
      filter_requests << { unmerge_cells: { range: merge } }
    end
    # フィルタ設定
    filter_requests << {
      set_basic_filter: {
        filter: {
          range: { sheet_id: sheet_id, start_row_index: 2, start_column_index: 0, end_column_index: 9 }
        }
      }
    }
    batch2 = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: filter_requests)
    @service.batch_update_spreadsheet(@spreadsheet_id, batch2) rescue nil
  end

  def format_rows(sheet_id, start_row, end_row, color, bold = false)
    cell_format = { background_color: color }
    cell_format[:text_format] = { bold: true } if bold

    {
      repeat_cell: {
        range: {
          sheet_id: sheet_id,
          start_row_index: start_row,
          end_row_index: end_row,
          start_column_index: 0,
          end_column_index: 9
        },
        cell: { user_entered_format: cell_format },
        fields: "userEnteredFormat(backgroundColor#{bold ? ',textFormat' : ''})"
      }
    }
  end
end
