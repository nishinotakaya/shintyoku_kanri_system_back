require "google/apis/sheets_v4"

# 西野・川村の Notion(WBS) タスクを、Backlog の上司報告とは「別の」スプレッドシートへ書き出す。
# 開始日/終了日は「修正前(前回同期値) / 修正後(今のNotion値)」の2列に分け、日付型(カレンダー扱い)で書き出す。
#   列: 担当 / WBSレベル / タスク名 / 開始日(修正前) / 開始日(修正後) / 終了日(修正前) / 終了日(修正後)
#       / 工数(人日) / 進捗率 / 進捗状況 / 優先度 / 備考
# 指定タブ(Notion(WBS))は全再生成する。
class NotionTaskExporter
  include BacklogSheetAuth
  TAB    = "Notion(WBS)".freeze
  HEADER = [ "担当", "WBSレベル", "タスク名",
             "開始日(修正前)", "開始日(修正後)", "終了日(修正前)", "終了日(修正後)",
             "工数(人日)", "進捗率(修正前)", "進捗率(修正後)", "進捗状況(修正前)", "進捗状況(修正後)",
             "優先度", "備考", "メモ" ].freeze
  HEADER_BG = { red: 0.16, green: 0.32, blue: 0.55 }.freeze
  DATE_COLS = [ 3, 4, 5, 6 ].freeze # 開始(前/後)・終了(前/後)
  STATUS_COL = 11 # 進捗状況(修正後) をプルダウンにする列
  WRAP_COLS  = [ 13, 14 ].freeze # 備考・メモ（改行を保持して折り返し表示）
  NCOL = 15

  def initialize(operator:, spreadsheet_url:)
    @operator = operator
    @spreadsheet_id = extract_spreadsheet_id(spreadsheet_url)
  end

  def call
    service = authorized_sheets_service(@spreadsheet_id, @operator)
    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    ensure_tab!(service, spreadsheet)
    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    sheet_id = spreadsheet.sheets.find { |s| s.properties.title == TAB }.properties.sheet_id

    values = [ HEADER ] + task_rows
    set_date_columns(service, sheet_id, DATE_COLS) # 開始/終了を「日付」型に（カレンダー扱い）
    service.clear_values(@spreadsheet_id, "#{TAB}!A1:Z2000")
    service.update_spreadsheet_value(@spreadsheet_id, "#{TAB}!A1",
      S::ValueRange.new(values: values), value_input_option: "USER_ENTERED")
    format(service, sheet_id)

    { spreadsheet_id: @spreadsheet_id,
      url: "https://docs.google.com/spreadsheets/d/#{@spreadsheet_id}/edit",
      tab: TAB, rows: task_rows.size }
  rescue Google::Apis::ClientError => e
    raise "Notion スプレッドシートへの書き込みに失敗しました（権限を確認してください）: #{e.message}"
  end

  private

  def pct(rate) = rate.nil? ? "" : "#{(rate.to_f * 100).round}%"

  def tasks = @tasks ||= NotionTask.order(:assignee_name, :wbs_level).to_a

  def task_rows
    @task_rows ||= tasks.map do |task|
      [ task.assignee_name.to_s, task.wbs_level.to_s, task.title.to_s,
        task.start_date&.to_s.to_s, task.start_date_prev&.to_s.to_s,
        task.end_date&.to_s.to_s, task.end_date_prev&.to_s.to_s,
        task.workload&.to_s.to_s,
        pct(task.progress_rate), pct(task.progress_rate_prev),
        task.status.to_s, task.status_prev.to_s,
        task.priority.to_s, task.note.to_s, task.memo.to_s ] # 備考・メモは改行をそのまま保持
    end
  end

  # 進捗状況(修正後)プルダウンの選択肢: 実データにある進捗状況 + 標準3種。
  def status_options
    (tasks.map { |t| t.status.to_s.strip } + tasks.map { |t| t.status_prev.to_s.strip } + %w[未着手 進行中 完了])
      .reject(&:empty?).uniq
  end

  def ensure_tab!(service, spreadsheet)
    return if spreadsheet.sheets.any? { |s| s.properties.title == TAB }
    service.batch_update_spreadsheet(@spreadsheet_id, S::BatchUpdateSpreadsheetRequest.new(requests: [
      S::Request.new(add_sheet: S::AddSheetRequest.new(properties: S::SheetProperties.new(title: TAB)))
    ]))
  end

  def format(service, sheet_id)
    reqs = []
    reqs << S::Request.new(repeat_cell: S::RepeatCellRequest.new(
      range: S::GridRange.new(sheet_id: sheet_id, start_row_index: 0, end_row_index: 1, start_column_index: 0, end_column_index: NCOL),
      cell: S::CellData.new(user_entered_format: S::CellFormat.new(
        background_color: S::Color.new(red: HEADER_BG[:red], green: HEADER_BG[:green], blue: HEADER_BG[:blue]),
        text_format: S::TextFormat.new(bold: true, foreground_color: S::Color.new(red: 1, green: 1, blue: 1)))),
      fields: "userEnteredFormat(backgroundColor,textFormat)"))
    reqs << S::Request.new(update_sheet_properties: S::UpdateSheetPropertiesRequest.new(
      properties: S::SheetProperties.new(sheet_id: sheet_id, grid_properties: S::GridProperties.new(frozen_row_count: 1)),
      fields: "gridProperties.frozenRowCount"))
    [ [ 0, 88 ], [ 1, 96 ], [ 2, 230 ], [ 3, 104 ], [ 4, 104 ], [ 5, 104 ], [ 6, 104 ], [ 7, 78 ], [ 8, 96 ], [ 9, 96 ], [ 10, 100 ], [ 11, 100 ], [ 12, 64 ], [ 13, 300 ], [ 14, 300 ] ].each do |i, px|
      reqs << S::Request.new(update_dimension_properties: S::UpdateDimensionPropertiesRequest.new(
        range: S::DimensionRange.new(sheet_id: sheet_id, dimension: "COLUMNS", start_index: i, end_index: i + 1),
        properties: S::DimensionProperties.new(pixel_size: px), fields: "pixelSize"))
    end

    # 備考・メモ: 改行を保持して折り返し表示（上揃え）
    last_row = tasks.size + 1
    WRAP_COLS.each do |i|
      reqs << S::Request.new(repeat_cell: S::RepeatCellRequest.new(
        range: S::GridRange.new(sheet_id: sheet_id, start_row_index: 1, end_row_index: last_row, start_column_index: i, end_column_index: i + 1),
        cell: S::CellData.new(user_entered_format: S::CellFormat.new(wrap_strategy: "WRAP", vertical_alignment: "TOP")),
        fields: "userEnteredFormat(wrapStrategy,verticalAlignment)"))
    end

    # 進捗状況(修正後): プルダウン(セレクトボックス)にする
    if tasks.any?
      reqs << S::Request.new(set_data_validation: S::SetDataValidationRequest.new(
        range: S::GridRange.new(sheet_id: sheet_id, start_row_index: 1, end_row_index: last_row, start_column_index: STATUS_COL, end_column_index: STATUS_COL + 1),
        rule: S::DataValidationRule.new(
          condition: S::BooleanCondition.new(type: "ONE_OF_LIST", values: status_options.map { |v| S::ConditionValue.new(user_entered_value: v) }),
          strict: false, show_custom_ui: true)))
    end

    service.batch_update_spreadsheet(@spreadsheet_id, S::BatchUpdateSpreadsheetRequest.new(requests: reqs))
  end

  # 指定列を「日付(yyyy-mm-dd)」型に。USER_ENTERED で "2026-06-30" を書くと日付シリアルとして扱われる。
  def set_date_columns(service, sheet_id, col_indexes)
    reqs = col_indexes.map do |i|
      S::Request.new(repeat_cell: S::RepeatCellRequest.new(
        range: S::GridRange.new(sheet_id: sheet_id, start_column_index: i, end_column_index: i + 1),
        cell: S::CellData.new(user_entered_format: S::CellFormat.new(
          number_format: S::NumberFormat.new(type: "DATE", pattern: "yyyy-mm-dd"))),
        fields: "userEnteredFormat.numberFormat"))
    end
    service.batch_update_spreadsheet(@spreadsheet_id, S::BatchUpdateSpreadsheetRequest.new(requests: reqs))
  end
end
