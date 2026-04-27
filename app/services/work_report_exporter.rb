require "fileutils"

# Wing 業務報告書テンプレートに月次データを差し込む。
# テンプレートは XlsxFiller (openpyxl) 経由で書式維持。
# シート名を対象月に合わせてリネーム（例: 業務報告（西野）_4月）。
class WorkReportExporter
  TEMPLATE = Rails.root.join("app/templates/work_report_template.xlsx")

  HEADER_NAME_ROW = 4   # Excel 行 (1-indexed)
  HEADER_NAME_COL = 3   # C
  DATA_START_ROW  = 7

  COL_DATE    = 1   # A
  COL_CONTENT = 3   # C
  COL_HOURS   = 24  # X
  COL_TRANSIT = 26  # Z
  COL_FEE     = 27  # AA

  def initialize(user, year:, month:, category: nil)
    @user = user
    @year = year
    @month = month
    @category = category.presence
  end

  def call
    cells = []

    # 氏名
    display = @user.display_name.to_s.gsub(/\s+/, " ").strip
    cells << { row: HEADER_NAME_ROW, col: HEADER_NAME_COL, value: display } if display.present?

    # 締日ベースの期間
    period = @user.period_for(@year, @month)
    scope = @user.work_reports.in_range(period)
    scope = scope.where(category: @category) if @category
    reports_by_date = scope.index_by(&:work_date)

    period.each_with_index do |date, i|
      row = DATA_START_ROW + i
      report = reports_by_date[date]

      cells << { row: row, col: COL_DATE, value: date.iso8601, type: "date" }
      cells << { row: row, col: COL_CONTENT, value: report&.content }
      cells << { row: row, col: COL_HOURS,   value: report&.hours&.to_f }
      cells << { row: row, col: COL_TRANSIT, value: report&.transit_section }
      cells << { row: row, col: COL_FEE,     value: report&.transit_fee }
    end

    # テンプレのサンプル行（期間外に残るもの）を明示クリア
    # 38 行目までがデータ領域（行39 = "合計時間"ラベル, 行40 = SUM 数式）
    sample_end = 38
    last_period_row = DATA_START_ROW + period.count - 1
    if last_period_row < sample_end
      (last_period_row + 1..sample_end).each do |row|
        [ COL_DATE, COL_CONTENT, COL_HOURS, COL_TRANSIT, COL_FEE ].each do |col|
          cells << { row: row, col: col, value: nil }
        end
      end
    end

    # シート名: 業務報告（西野）_4月  ← 姓 + 対象月
    surname = display.split(/[\s　]/).first || display
    sheet_name = "業務報告（#{surname}）_#{@month}月"

    # A1 ヘッダ日付: 対象月の 1 日
    header_date = Date.new(@year, @month, 1).iso8601

    out_dir = Rails.root.join("tmp/exports")
    out = out_dir.join("work_report_#{@user.id}_#{@year}_#{@month}_#{SecureRandom.hex(4)}.xlsx").to_s
    XlsxFiller.call(
      template: TEMPLATE,
      output: out,
      sheet: 0,
      cells: cells,
      sheet_name: sheet_name,
      header_date: header_date
    )
    out
  end
end
