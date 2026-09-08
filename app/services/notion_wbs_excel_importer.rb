# ISN(川村さん)が編集した進捗報告書Excel(.xlsx/.xlsm)「プロジェクトのスケジュール」シートを読み、
# アプリ側の元の値(Notion同期値: progress_rate/workload/start_date/end_date)と異なるセルだけを
# NotionTask の *_prev(修正後)へ反映する。アップロードされた Excel を正として扱うため、
# シートの値がアプリの元の値と同じセルは(既に *_prev があっても)クリアする。
# 一致・不一致・突合キーの正規化は WbsExcelDocument / NotionWbsExcelUpdater と共有する。
# セル値のパース・同値判定は WbsScheduleCellParser を WbsTemplateValuesReader と共有する。
class NotionWbsExcelImporter
  SHEET_NAME     = WbsExcelDocument::SHEET_NAME
  DATA_FIRST_ROW = 8
  DATA_LAST_ROW  = 183
  NAMESPACES     = WbsExcelDocument::NAMESPACES

  # 取込対象は進捗率・工数・開始日・終了日の4項目のみ(タスク名・担当者は取り込まない)
  Field = Struct.new(:column, :attribute, :kind)
  FIELDS = [
    Field.new("E", :progress_rate, :rate),
    Field.new("F", :workload, :number),
    Field.new("G", :start_date, :date),
    Field.new("H", :end_date, :date)
  ].freeze

  def initialize(workbook_bytes:, tasks:)
    @workbook_bytes = workbook_bytes
    @tasks = Array(tasks)
  end

  def call
    document = WbsExcelDocument.new(@workbook_bytes)
    raise "「#{SHEET_NAME}」シートが見つかりません" if document.sheet_path.nil?

    task_by_wbs_level = index_tasks_by_wbs_level
    applied_task_count = 0
    applied_cell_count = 0
    cleared_cell_count = 0
    unmatched_row_count = 0
    unchanged_row_count = 0

    NotionTask.transaction do
      each_data_row(document.sheet_document) do |row_node|
        wbs_level_text = document.cell_text_value(document.find_cell(row_node, "B"))
        next if wbs_level_text.blank?

        task = task_by_wbs_level[WbsExcelDocument.normalize_wbs_level(wbs_level_text)]
        if task.nil?
          unmatched_row_count += 1
          next
        end

        cell_counts = apply_row!(document, row_node, task)
        applied_cell_count += cell_counts[:applied]
        cleared_cell_count += cell_counts[:cleared]

        if cell_counts[:applied].zero? && cell_counts[:cleared].zero?
          unchanged_row_count += 1
        else
          task.save!
          applied_task_count += 1
        end
      end
    end

    { applied_task_count: applied_task_count, applied_cell_count: applied_cell_count,
      cleared_cell_count: cleared_cell_count, unmatched_row_count: unmatched_row_count,
      unchanged_row_count: unchanged_row_count }
  end

  private

  def index_tasks_by_wbs_level
    index = {}
    @tasks.each do |task|
      wbs_level = WbsExcelDocument.normalize_wbs_level(task.wbs_level)
      next if wbs_level.blank?

      index[wbs_level] ||= task # 重複するWBSレベルは最初の1件だけを索引する
    end
    index
  end

  def each_data_row(sheet_document)
    sheet_document.xpath("//main:sheetData/main:row", NAMESPACES).each do |row_node|
      row_number = row_node["r"].to_i
      next unless row_number.between?(DATA_FIRST_ROW, DATA_LAST_ROW)

      yield row_node
    end
  end

  # 1行分の4項目を判定し、変更が必要なセルだけ task の *_prev に反映する(保存はしない)。
  # 戻り値は { applied:, cleared: }(このメソッド内で書き換えたセル数)。
  def apply_row!(document, row_node, task)
    applied = 0
    cleared = 0

    FIELDS.each do |field|
      cell_text = document.cell_text_value(document.find_cell(row_node, field.column))
      cell_value = WbsScheduleCellParser.parse_cell_value(field.kind, cell_text)
      next if cell_value.nil? # 空セルは「変更なし」として扱う(アプリの値を消さない)

      original_value = task.public_send(field.attribute)
      target_value = WbsScheduleCellParser.values_equal?(field.kind, original_value, cell_value) ? nil : cell_value
      current_prev_value = task.public_send("#{field.attribute}_prev")
      next if WbsScheduleCellParser.values_equal?(field.kind, current_prev_value, target_value) # 既に同じ状態なら触らない

      task.public_send("#{field.attribute}_prev=", target_value)
      target_value.nil? ? (cleared += 1) : (applied += 1)
    end

    { applied: applied, cleared: cleared }
  end
end
