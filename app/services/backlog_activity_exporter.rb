require "google/apis/sheets_v4"

# 川村さん等の Backlog 対応ログ(BacklogActivity)を、ユーザーが手で整えた
# 「月次サマリ」シートに【非破壊で】反映する。
#   サマリ列: 月 / 課題 / 概要 / 状態推移 / 開始日 / 処理済日 / 完了日 / 備考 / 担当者
#   ・既存行: 空いている日付セル(開始日/処理済日/完了日)と空の担当者だけ埋める。状態・概要・備考・手入力は一切触らない。
#   ・新規課題(月×課題): 末尾に行を追加。
#   担当者列(末尾)は、そのログの持ち主(西野 or 川村)を入れて、シート上で担当者フィルタできるようにする。
#   詳細タブ(対応ログ詳細)は活動ログそのものなので全再生成する。
class BacklogActivityExporter
  include BacklogSheetAuth
  DETAIL_TAB = "対応ログ詳細".freeze
  HEADER_BG  = { red: 0.15, green: 0.22, blue: 0.33 }.freeze

  # サマリの列位置 (0-indexed)
  COL_MONTH = 0
  COL_ISSUE = 1
  COL_SUMMARY = 2
  COL_STATUS = 3
  COL_START = 4
  COL_SHORI = 5  # 処理済日
  COL_DONE  = 6  # 完了日
  COL_NOTE  = 7  # 備考
  COL_ASSIGNEE = 8 # 担当者(末尾。西野 or 川村でフィルタするため)
  DATE_COLS = [ COL_START, COL_SHORI, COL_DONE ].freeze
  SUMMARY_NCOL = 9

  def initialize(user:, operator:, spreadsheet_url:)
    @user = user
    @operator = operator
    @spreadsheet_id = extract_spreadsheet_id(spreadsheet_url)
    @backlog_url = user.backlog_setting&.backlog_url.to_s.chomp("/")
  end

  def call
    service = authorized_sheets_service(@spreadsheet_id, @operator)
    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    summary_tab = spreadsheet.sheets.first.properties.title # 先頭タブ(gid=0)。名前は変えない。
    ensure_detail_tab!(service, spreadsheet)
    spreadsheet = service.get_spreadsheet(@spreadsheet_id)

    @summary_sheet_id = spreadsheet.sheets.first.properties.sheet_id
    result = update_summary(service, summary_tab)
    rewrite_detail(service, spreadsheet)

    { spreadsheet_id: @spreadsheet_id,
      url: "https://docs.google.com/spreadsheets/d/#{@spreadsheet_id}/edit",
      filled_dates: result[:filled], appended_rows: result[:appended] }
  rescue Google::Apis::ClientError => e
    raise "スプレッドシートへの書き込みに失敗しました（権限を確認してください）: #{e.message}"
  end

  private

  def ensure_detail_tab!(service, spreadsheet)
    return if spreadsheet.sheets.any? { |s| s.properties.title == DETAIL_TAB }
    service.batch_update_spreadsheet(@spreadsheet_id, S::BatchUpdateSpreadsheetRequest.new(requests: [
      S::Request.new(add_sheet: S::AddSheetRequest.new(properties: S::SheetProperties.new(title: DETAIL_TAB)))
    ]))
  end

  # 担当者列に入れる名前 = その課題の Backlog 上の実担当者(ログの持ち主ではない)。
  # 課題キーごとに Backlog から取得してキャッシュする。未アサイン/取得失敗は ""。
  def assignee_for(issue_key)
    key = issue_key.to_s[/[A-Z]+-\d+/]
    return "" if key.blank?
    (@assignee_cache ||= {})[key] ||= backlog_client.fetch_assignee_name(key)
  end

  def backlog_client = @backlog_client ||= BacklogClient.new(@user.backlog_setting)

  # ── Backlog 由来の集計 ───────────────────────
  def activities = @activities ||= @user.backlog_activities.order(:occurred_on, :activity_id).to_a

  # 上司報告サマリ行（月/課題/概要/状態推移/開始日/処理済日/完了日/備考）の単一窓口。
  def summary = @summary ||= BacklogActivitySummary.new(@user)
  def summary_by_key = @summary_by_key ||= summary.rows.index_by { |r| [ r[:month], r[:issue_key] ] }

  def issue_key_from(cell)
    text = cell.to_s
    text[/[A-Z]+-\d+/] || (text.strip.start_with?("資料:") ? text.strip : nil) # 「資料:カテゴリ」の備考専用行も突合対象
  end

  def link(issue_key)
    return issue_key if @backlog_url.blank?
    return issue_key unless issue_key =~ /\A[A-Z]+-\d+\z/ # Backlog課題キー以外(資料行など)はリンクにしない
    %Q(=HYPERLINK("#{@backlog_url}/view/#{issue_key}","#{issue_key}"))
  end

  # ── サマリ更新(非破壊) ───────────────────────
  # 既存行: 空の「処理済日 / 完了日」を埋め、アプリに手入力がある備考だけ書き戻す（空で潰さない）。
  #         月 / 課題 / 概要 / 状態推移 / 開始日 / 書式 は触らない。
  # 新規行: シートに無い 月×課題 を末尾に追加し、テンプレートにデータが揃うようにする。
  def update_summary(service, tab)
    rows = service.get_spreadsheet_values(@spreadsheet_id, "#{tab}!A1:I1000").values || [] # FORMATTED(表示値)
    header_idx = rows.index { |r| Array(r).include?("課題") }
    raise "サマリシートに『課題』ヘッダが見つかりません（テンプレートを確認してください）。" unless header_idx

    existing_keys = {}
    updates = []
    # 担当者ヘッダが未設定なら書く(既存テンプレは 備考 までの8列想定)
    if rows[header_idx].to_a[COL_ASSIGNEE].to_s.strip != "担当者"
      updates << S::ValueRange.new(range: "#{tab}!#{col_letter(COL_ASSIGNEE)}#{header_idx + 1}", values: [ [ "担当者" ] ])
    end
    (header_idx + 1...rows.size).each do |i|
      row = rows[i] || []
      key = issue_key_from(row[COL_ISSUE])
      next if key.blank?
      month = row[COL_MONTH].to_s.strip
      existing_keys[[ month, key ]] = i
      info = summary_by_key[[ month, key ]] or next

      { COL_SHORI => info[:shori_on], COL_DONE => info[:done_on] }.each do |col, val|
        next if val.blank?
        next if row[col].to_s.strip.present? # 既存値(手入力含む)は絶対に上書きしない
        updates << S::ValueRange.new(range: "#{tab}!#{col_letter(col)}#{i + 1}", values: [ [ val.to_s ] ])
      end
      # 担当者(派生列)は Backlog の実担当者に合わせる。誤り(旧ロジックのログ持ち主名)や空を上書き修正する。
      real_assignee = assignee_for(key)
      if real_assignee.present? && row[COL_ASSIGNEE].to_s.strip != real_assignee
        updates << S::ValueRange.new(range: "#{tab}!#{col_letter(COL_ASSIGNEE)}#{i + 1}", values: [ [ real_assignee ] ])
      end
      note = info[:note].to_s.strip
      if note.present? && row[COL_NOTE].to_s.strip != note
        if note =~ URL_RE
          note_link_cells << [ i, note ] # URL入り備考はリッチテキストリンクで書く
        else
          updates << S::ValueRange.new(range: "#{tab}!#{col_letter(COL_NOTE)}#{i + 1}", values: [ [ note ] ])
        end
      end
    end
    unless updates.empty?
      service.batch_update_values(@spreadsheet_id, S::BatchUpdateValuesRequest.new(
        value_input_option: "USER_ENTERED", data: updates))
    end

    appended = append_new_rows(service, tab, rows.size, existing_keys)
    linkify_note_cells(service)
    { filled: updates.size + note_link_cells.size, appended: appended }
  end

  # ── 備考セル内の URL をクリック可能なリンク(リッチテキスト)にする ──
  URL_RE = %r{https?://[^\s)"'　]+}

  def note_link_cells = @note_link_cells ||= []

  def linkify_note_cells(service)
    requests = note_link_cells.filter_map do |row_index, text|
      matches = []
      text.scan(URL_RE) { matches << [ Regexp.last_match.begin(0), Regexp.last_match(0) ] }
      next if matches.empty?
      runs = []
      matches.each do |start_index, url|
        runs << S::TextFormatRun.new(start_index: start_index, format: S::TextFormat.new(
          link: S::Link.new(uri: url),
          foreground_color: S::Color.new(red: 0.06, green: 0.45, blue: 0.87), underline: true))
        end_index = start_index + url.length
        runs << S::TextFormatRun.new(start_index: end_index, format: S::TextFormat.new) if end_index < text.length
      end
      S::Request.new(update_cells: S::UpdateCellsRequest.new(
        start: S::GridCoordinate.new(sheet_id: @summary_sheet_id, row_index: row_index, column_index: COL_NOTE),
        rows: [ S::RowData.new(values: [ S::CellData.new(
          user_entered_value: S::ExtendedValue.new(string_value: text),
          text_format_runs: runs,
          user_entered_format: S::CellFormat.new(wrap_strategy: "WRAP", vertical_alignment: "TOP")) ]) ],
        fields: "userEnteredValue,textFormatRuns,userEnteredFormat(wrapStrategy,verticalAlignment)"))
    end
    return if requests.empty?
    service.batch_update_spreadsheet(@spreadsheet_id, S::BatchUpdateSpreadsheetRequest.new(requests: requests))
  end

  # シートにまだ無い 月×課題 を末尾に追加する。
  def append_new_rows(service, tab, sheet_row_count, existing_keys)
    new_keys = summary_by_key.keys.reject { |key| existing_keys.key?(key) }.sort
    return 0 if new_keys.empty?

    values = new_keys.map do |month, key|
      info = summary_by_key[[ month, key ]]
      [ month, link(key), info[:summary], info[:status],
        info[:start_on], info[:shori_on], info[:done_on], info[:note], assignee_for(key) ]
    end
    service.update_spreadsheet_value(@spreadsheet_id, "#{tab}!A#{sheet_row_count + 1}",
      S::ValueRange.new(values: values), value_input_option: "USER_ENTERED")
    # 追加行の備考にURLがあればリンク化対象に積む(0-based行index = 追加開始行 + オフセット)
    new_keys.each_with_index do |key_pair, offset|
      note = summary_by_key[key_pair][:note].to_s
      note_link_cells << [ sheet_row_count + offset, note ] if note =~ URL_RE
    end
    values.size
  end

  # ── 詳細タブ(全再生成・担当者列つき) ───────────────────────
  #   詳細タブは「そのユーザーの活動ログ」なので単一ユーザーで全再生成する。
  #   担当者(G列)は各課題の Backlog 実担当者を入れる(ログ持ち主ではない)。
  def rewrite_detail(service, spreadsheet)
    header = %w[月 日付 課題 概要 種別 内容 担当者]
    rows = activities.sort_by { |a| [ a.month, a.occurred_on.to_s, a.activity_id ] }.map do |a|
      [ a.month, a.occurred_on.to_s, link(a.issue_key), a.summary.to_s,
        BacklogActivity::TYPE_LABELS[a.activity_type] || a.activity_type, a.content.to_s.gsub(/\s+/, " "), assignee_for(a.issue_key) ]
    end
    values = [ header ] + rows
    sheet = spreadsheet.sheets.find { |s| s.properties.title == DETAIL_TAB }
    sheet_id = sheet.properties.sheet_id
    set_text_columns(service, sheet_id, [ 0, 1 ]) # 月・日付
    service.clear_values(@spreadsheet_id, "#{DETAIL_TAB}!A1:Z5000")
    service.update_spreadsheet_value(@spreadsheet_id, "#{DETAIL_TAB}!A1",
      S::ValueRange.new(values: values), value_input_option: "USER_ENTERED")
    format_detail(service, sheet_id, values.size)
  end

  def format_detail(service, sheet_id, nrows)
    reqs = []
    reqs << S::Request.new(repeat_cell: S::RepeatCellRequest.new(
      range: S::GridRange.new(sheet_id: sheet_id, start_row_index: 0, end_row_index: 1, start_column_index: 0, end_column_index: 7),
      cell: S::CellData.new(user_entered_format: S::CellFormat.new(
        background_color: S::Color.new(red: HEADER_BG[:red], green: HEADER_BG[:green], blue: HEADER_BG[:blue]),
        text_format: S::TextFormat.new(bold: true, foreground_color: S::Color.new(red: 1, green: 1, blue: 1)))),
      fields: "userEnteredFormat(backgroundColor,textFormat)"))
    reqs << S::Request.new(repeat_cell: S::RepeatCellRequest.new(
      range: S::GridRange.new(sheet_id: sheet_id, start_row_index: 1, end_row_index: [ nrows, 1 ].max, start_column_index: 0, end_column_index: 7),
      cell: S::CellData.new(user_entered_format: S::CellFormat.new(wrap_strategy: "WRAP", vertical_alignment: "TOP")),
      fields: "userEnteredFormat(wrapStrategy,verticalAlignment)"))
    reqs << S::Request.new(update_sheet_properties: S::UpdateSheetPropertiesRequest.new(
      properties: S::SheetProperties.new(sheet_id: sheet_id, grid_properties: S::GridProperties.new(frozen_row_count: 1)),
      fields: "gridProperties.frozenRowCount"))
    [ [ 0, 70 ], [ 1, 90 ], [ 2, 90 ], [ 3, 200 ], [ 4, 90 ], [ 5, 520 ], [ 6, 100 ] ].each do |i, px|
      reqs << S::Request.new(update_dimension_properties: S::UpdateDimensionPropertiesRequest.new(
        range: S::DimensionRange.new(sheet_id: sheet_id, dimension: "COLUMNS", start_index: i, end_index: i + 1),
        properties: S::DimensionProperties.new(pixel_size: px), fields: "pixelSize"))
    end
    service.batch_update_spreadsheet(@spreadsheet_id, S::BatchUpdateSpreadsheetRequest.new(requests: reqs))
  end

  # 指定列を TEXT 書式に（"2026-04" 等を日付シリアルに変換させない）
  def set_text_columns(service, sheet_id, col_indexes)
    reqs = col_indexes.map do |i|
      S::Request.new(repeat_cell: S::RepeatCellRequest.new(
        range: S::GridRange.new(sheet_id: sheet_id, start_column_index: i, end_column_index: i + 1),
        cell: S::CellData.new(user_entered_format: S::CellFormat.new(
          number_format: S::NumberFormat.new(type: "TEXT", pattern: "@"))),
        fields: "userEnteredFormat.numberFormat"))
    end
    service.batch_update_spreadsheet(@spreadsheet_id, S::BatchUpdateSpreadsheetRequest.new(requests: reqs))
  end

  def col_letter(idx) = ("A".ord + idx).chr
end
