require "google/apis/sheets_v4"

# Notion(WBS) タブのスプレッドシートを読み、notion_tasks に取り込む（スプシ→アプリ）。
# WBSレベルで突合し、「修正後」の開始/終了日・工数・進捗率・進捗状況・優先度・備考を更新する。
#   ・修正前(*_prev) は Notion 同期が管理するので取り込まない。
#   ・空セルでアプリの値を消さない（present な時だけ set）。
#   ・シートに無い WBS 行はスキップ（新規作成はしない）。
# 注意: 次の Notion 同期で start_date/end_date/各値は Notion 側の値に上書きされる（手修正は一時的）。
class NotionTaskImporter
  include BacklogSheetAuth
  TAB = NotionTaskExporter::TAB

  # 列インデックス（Exporter と同じ並び）
  COL_ASSIGNEE = 0
  COL_WBS      = 1
  COL_START_NOW  = 3  # 開始日(修正前)=現在値 → start_date
  COL_START_PREV = 4  # 開始日(修正後)=前回値 → start_date_prev
  COL_END_NOW    = 5  # 終了日(修正前)=現在値 → end_date
  COL_END_PREV   = 6  # 終了日(修正後)=前回値 → end_date_prev
  COL_WORKLOAD   = 7
  COL_PROGRESS_NOW  = 8  # 進捗率(修正前) → progress_rate
  COL_PROGRESS_PREV = 9  # 進捗率(修正後) → progress_rate_prev
  COL_STATUS_NOW    = 10 # 進捗状況(修正前) → status
  COL_STATUS_PREV   = 11 # 進捗状況(修正後) → status_prev
  COL_PRIORITY = 12
  COL_NOTE     = 13
  COL_MEMO     = 14

  def initialize(operator:, spreadsheet_url:)
    @operator = operator
    @spreadsheet_id = extract_spreadsheet_id(spreadsheet_url)
  end

  def call
    service = authorized_sheets_service(@spreadsheet_id, @operator)
    resp = service.get_spreadsheet_values(@spreadsheet_id, "#{TAB}!A1:N1000", value_render_option: "UNFORMATTED_VALUE")
    rows = resp.values || []
    header_idx = rows.index { |row| Array(row).any? { |cell| cell.to_s.include?("WBS") } }
    raise "Notion(WBS) シートが見つかりません（先に「Notion出力」してください）。" if header_idx.nil?

    by_wbs = NotionTask.where.not(wbs_level: [ nil, "" ]).index_by { |task| task.wbs_level.to_s.strip }
    updated = 0
    skipped = 0

    (header_idx + 1...rows.size).each do |i|
      row = rows[i] || []
      wbs = row[COL_WBS].to_s.strip
      next if wbs.blank?
      task = by_wbs[wbs]
      if task.nil?
        skipped += 1
        next
      end
      task.start_date      = to_date(row[COL_START_NOW])  if filled?(row[COL_START_NOW])
      task.start_date_prev = to_date(row[COL_START_PREV]) if filled?(row[COL_START_PREV])
      task.end_date        = to_date(row[COL_END_NOW])    if filled?(row[COL_END_NOW])
      task.end_date_prev   = to_date(row[COL_END_PREV])   if filled?(row[COL_END_PREV])
      task.workload           = row[COL_WORKLOAD].to_f         if filled?(row[COL_WORKLOAD])
      task.progress_rate      = to_rate(row[COL_PROGRESS_NOW]) if filled?(row[COL_PROGRESS_NOW])
      task.progress_rate_prev = to_rate(row[COL_PROGRESS_PREV]) if filled?(row[COL_PROGRESS_PREV])
      task.status        = text(row[COL_STATUS_NOW])  if filled?(row[COL_STATUS_NOW])
      task.status_prev   = text(row[COL_STATUS_PREV]) if filled?(row[COL_STATUS_PREV])
      task.priority      = text(row[COL_PRIORITY])    if filled?(row[COL_PRIORITY])
      task.note          = text(row[COL_NOTE])        if filled?(row[COL_NOTE])
      task.memo          = row[COL_MEMO].to_s          if row[COL_MEMO] # メモは空文字も反映(消去も取り込む)
      if task.changed?
        task.save!
        updated += 1
      end
    end

    { imported_rows: updated, skipped_rows: skipped, tab: TAB,
      url: "https://docs.google.com/spreadsheets/d/#{@spreadsheet_id}/edit" }
  rescue Google::Apis::ClientError => e
    raise "Notion スプレッドシートからの取り込みに失敗しました（権限を確認してください）: #{e.message}"
  end

  private

  def filled?(cell) = !cell.nil? && cell.to_s.strip != ""
  def text(cell) = (stripped = cell.to_s.strip).empty? ? nil : stripped

  # UNFORMATTED_VALUE では日付はシリアル値(1899-12-30 起点)。文字列日付にもフォールバック。
  def to_date(cell)
    return nil unless filled?(cell)
    return Date.new(1899, 12, 30) + cell.to_i if cell.is_a?(Numeric)
    Date.parse(cell.to_s)
  rescue ArgumentError
    nil
  end

  # "60%"→0.6 / 0.6→0.6 / 60→0.6 を吸収（progress_rate は 0.0〜1.0 で保存）。
  def to_rate(cell)
    return nil unless filled?(cell)
    value = cell.to_s.delete("%").to_f
    value > 1 ? value / 100.0 : value
  end
end
