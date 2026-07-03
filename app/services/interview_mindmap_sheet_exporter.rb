require "google/apis/sheets_v4"

# 面談対策マインドマップを Google スプレッドシートへ書き出す。
# 深さ(depth)を列に割り当てて、Q/A を左→右にインデント表示する（横に広がるツリー）。
# 書き込みは管理者(西野)トークン(GoogleAuth.build_writer)。対象シートは西野に編集者共有が必要。
class InterviewMindmapSheetExporter
  MAX_DEPTH = 6

  def initialize(mindmap:, user:, spreadsheet_url:)
    @map = mindmap
    @user = user
    @url = spreadsheet_url.to_s.strip
  end

  def call
    sid = @url[%r{/spreadsheets/d/([a-zA-Z0-9_-]+)}, 1]
    raise "スプレッドシートの URL が不正です" unless sid

    rows, question_row_indexes, answer_row_indexes = build_rows
    svc = Google::Apis::SheetsV4::SheetsService.new
    svc.authorization = GoogleAuth.build_writer(@user)
    sheet = svc.get_spreadsheet(sid).sheets.first
    title = sheet.properties.title
    sheet_id = sheet.properties.sheet_id

    svc.clear_values(sid, "#{title}!A1:Z1000")
    svc.update_spreadsheet_value(sid, "#{title}!A1",
      Google::Apis::SheetsV4::ValueRange.new(values: rows), value_input_option: "RAW")
    # 先に全体の書式をリセット → Q行=太字15青、A行=太字12
    requests = [ reset_format_request(sheet_id, rows.size) ]
    # 全列の幅を半分(50px)に + セルのグリッド線(罫線)を消す
    requests << column_width_request(sheet_id, MAX_DEPTH + 2)
    requests << hide_gridlines_request(sheet_id)
    requests += question_row_indexes.map { |r| q_text_format_request(sheet_id, r) }
    requests += answer_row_indexes.map { |r| a_text_format_request(sheet_id, r) }
    svc.batch_update_spreadsheet(sid,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests)) if requests.any?
    { spreadsheet_id: sid, rows: rows.size }
  rescue Google::Apis::ClientError => e
    if e.status_code == 403
      raise "スプレッドシートへの書き込み権限がありません。対象シートを #{GoogleAuth.writer_user(@user)&.email} に「編集者」として共有してください。"
    end
    raise "書き込みに失敗しました: #{e.message}"
  end

  private

  def by_parent
    h = Hash.new { |hash, k| hash[k] = [] }
    @map.nodes.each { |n| h[n.parent_id] << n }
    h.each_value { |a| a.sort_by!(&:position) }
    h
  end

  def build_rows
    bp = by_parent
    width = MAX_DEPTH + 2 # 0..MAX_DEPTH の列 + 末尾チェック列
    rows = [ [ "面談対策マインドマップ: #{@map.title}" ] ]
    q_rows = []
    a_rows = []
    emit = lambda do |node, depth|
      return if node.kind == "keyword" # キーワードは出さない(QとAのみ)
      line = Array.new(width, "")
      col = [ depth, MAX_DEPTH ].min
      label = case node.kind
      when "answer" then "A: "
      when "root"   then "■ "
      else "Q: "
      end
      line[col] = "#{label}#{node.text}"
      line[width - 1] = node.checked ? "✓" : ""
      rows << line
      idx = rows.size - 1 # 0-based 行 index
      q_rows << idx if %w[question followup].include?(node.kind)
      a_rows << idx if node.kind == "answer"
      bp[node.id].each { |child| emit.call(child, depth + 1) }
    end
    bp[nil].each { |root| emit.call(root, 0) }
    [ rows, q_rows, a_rows ]
  end

  # 全体の書式を初期化（以前の背景色・太字などを消す）
  def reset_format_request(sheet_id, total_rows)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: Google::Apis::SheetsV4::GridRange.new(
        sheet_id: sheet_id, start_row_index: 0, end_row_index: [ total_rows, 1 ].max,
        start_column_index: 0, end_column_index: MAX_DEPTH + 2
      ),
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        background_color: Google::Apis::SheetsV4::Color.new(red: 1, green: 1, blue: 1),
        text_format: Google::Apis::SheetsV4::TextFormat.new(bold: false, font_size: 10,
          foreground_color: Google::Apis::SheetsV4::Color.new(red: 0, green: 0, blue: 0)))),
      fields: "userEnteredFormat(backgroundColor,textFormat)"))
  end

  # 全列の幅を半分(50px)にする
  def column_width_request(sheet_id, ncols)
    Google::Apis::SheetsV4::Request.new(update_dimension_properties: Google::Apis::SheetsV4::UpdateDimensionPropertiesRequest.new(
      range: Google::Apis::SheetsV4::DimensionRange.new(
        sheet_id: sheet_id, dimension: "COLUMNS", start_index: 0, end_index: ncols),
      properties: Google::Apis::SheetsV4::DimensionProperties.new(pixel_size: 50),
      fields: "pixelSize"))
  end

  # セルのグリッド線(罫線)を非表示にする
  def hide_gridlines_request(sheet_id)
    Google::Apis::SheetsV4::Request.new(update_sheet_properties: Google::Apis::SheetsV4::UpdateSheetPropertiesRequest.new(
      properties: Google::Apis::SheetsV4::SheetProperties.new(
        sheet_id: sheet_id,
        grid_properties: Google::Apis::SheetsV4::GridProperties.new(hide_gridlines: true)),
      fields: "gridProperties.hideGridlines"))
  end

  # Q 行(全列)を 太字・サイズ15・見やすい青文字 にする repeatCell リクエスト
  def q_text_format_request(sheet_id, row_index)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: Google::Apis::SheetsV4::GridRange.new(
        sheet_id: sheet_id, start_row_index: row_index, end_row_index: row_index + 1,
        start_column_index: 0, end_column_index: MAX_DEPTH + 2
      ),
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        text_format: Google::Apis::SheetsV4::TextFormat.new(
          bold: true, font_size: 14,
          foreground_color: Google::Apis::SheetsV4::Color.new(red: 0.10, green: 0.32, blue: 0.70)))),
      fields: "userEnteredFormat.textFormat"))
  end

  # A 行(全列)を 太字・サイズ11 にする repeatCell リクエスト
  def a_text_format_request(sheet_id, row_index)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: Google::Apis::SheetsV4::GridRange.new(
        sheet_id: sheet_id, start_row_index: row_index, end_row_index: row_index + 1,
        start_column_index: 0, end_column_index: MAX_DEPTH + 2
      ),
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        text_format: Google::Apis::SheetsV4::TextFormat.new(bold: true, font_size: 11))),
      fields: "userEnteredFormat.textFormat"))
  end
end
