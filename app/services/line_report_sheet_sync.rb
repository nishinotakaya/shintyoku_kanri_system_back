require "google/apis/sheets_v4"

# line_report_entries を Google スプレッドシート「進捗管理表_川村_西野」の月別タブ(YYYYMM)へ書き出す。
# タブの中身は毎回 DB から全量再生成する(冪等。同じ日付×同じタスクの上書きもそのまま反映される)。
# 書き込みは Google 連携済み admin(西野さん)のトークンで行う(GoogleAuth.build_writer)。
class LineReportSheetSync
  SPREADSHEET_ID = ENV.fetch("LINE_REPORT_SHEET_ID", "1dDp9gkW2sKSIMc1vS1C87yLXx2eslf5kkEZwfOs52lw")
  HEADER = [ "日付", "報告者", "タスク", "開始日", "終了日", "進捗率", "ステータス", "備考(遅れた理由など)", "リンク" ].freeze
  HEADER_BG = { red: 1.00, green: 0.95, blue: 0.60 }.freeze
  WEEKDAY_JA = %w[日 月 火 水 木 金 土].freeze
  COLUMN_WIDTHS = [ 70, 90, 260, 130, 130, 110, 130, 300, 260 ].freeze

  def self.sync(operator:, month:)
    new(operator: operator, month: month).call
  end

  def initialize(operator:, month:)
    @operator = operator
    @month_start = month.to_date.beginning_of_month
  end

  def call
    entries = LineReportEntry.in_month(@month_start).includes(:user).order(:reported_on, :user_id, :id)
    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = GoogleAuth.build_writer(@operator)

    sheet_id = ensure_month_sheet(service)
    rows = [ HEADER ] + entry_rows(entries)

    service.clear_values(SPREADSHEET_ID, "#{sheet_title}!A:Z")
    service.update_spreadsheet_value(
      SPREADSHEET_ID,
      "#{sheet_title}!A1",
      Google::Apis::SheetsV4::ValueRange.new(values: rows),
      value_input_option: "USER_ENTERED"
    )
    apply_format(service, sheet_id, rows.size)
    { sheet: sheet_title, rows: rows.size - 1 }
  end

  private

  def sheet_title = @month_start.strftime("%Y%m")

  def ensure_month_sheet(service)
    spreadsheet = service.get_spreadsheet(SPREADSHEET_ID)
    sheet = spreadsheet.sheets.find { |s| s.properties.title == sheet_title }
    return sheet.properties.sheet_id if sheet

    response = service.batch_update_spreadsheet(
      SPREADSHEET_ID,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(
        requests: [ { add_sheet: { properties: { title: sheet_title } } } ]
      )
    )
    response.replies.first.add_sheet.properties.sheet_id
  end

  # 日付は同じ日のかたまりの先頭行だけ、報告者は同じ日×同じ人のかたまりの先頭行だけ出して見やすくする
  def entry_rows(entries)
    previous_date = nil
    previous_reporter_key = nil
    entries.map do |entry|
      date_cell =
        if entry.reported_on == previous_date
          ""
        else
          "#{entry.reported_on.month}/#{entry.reported_on.day}(#{WEEKDAY_JA[entry.reported_on.wday]})"
        end
      reporter_key = [ entry.reported_on, entry.user_id ]
      reporter_cell = reporter_key == previous_reporter_key ? "" : entry.user.display_name
      previous_date = entry.reported_on
      previous_reporter_key = reporter_key

      [
        date_cell, reporter_cell, entry.task_title,
        entry.start_date_text.to_s, entry.end_date_text.to_s, entry.progress_text.to_s,
        entry.status_text.to_s, entry.note.to_s, entry.url.to_s
      ]
    end
  end

  def apply_format(service, sheet_id, total_rows)
    requests = [
      # ヘッダ行: 黄色地・太字・中央寄せ
      { repeat_cell: {
        range: { sheet_id: sheet_id, start_row_index: 0, end_row_index: 1, start_column_index: 0, end_column_index: HEADER.size },
        cell: { user_entered_format: {
          background_color: HEADER_BG, text_format: { bold: true }, horizontal_alignment: "CENTER"
        } },
        fields: "userEnteredFormat(backgroundColor,textFormat,horizontalAlignment)"
      } },
      # ヘッダ行を固定
      { update_sheet_properties: {
        properties: { sheet_id: sheet_id, grid_properties: { frozen_row_count: 1 } },
        fields: "gridProperties.frozenRowCount"
      } },
      # データ行: 折り返し・上寄せ
      { repeat_cell: {
        range: { sheet_id: sheet_id, start_row_index: 1, end_row_index: [ total_rows, 2 ].max, start_column_index: 0, end_column_index: HEADER.size },
        cell: { user_entered_format: { wrap_strategy: "WRAP", vertical_alignment: "TOP" } },
        fields: "userEnteredFormat(wrapStrategy,verticalAlignment)"
      } }
    ]
    COLUMN_WIDTHS.each_with_index do |width, index|
      requests << { update_dimension_properties: {
        range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: index, end_index: index + 1 },
        properties: { pixel_size: width },
        fields: "pixelSize"
      } }
    end
    service.batch_update_spreadsheet(
      SPREADSHEET_ID,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests)
    )
  end
end
