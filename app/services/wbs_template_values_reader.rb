# 登録済みテンプレ(xlsm)「プロジェクトのスケジュール」シートの E〜H列(進捗率・工数・開始日・終了日)を
# WBSレベルごとに読み取る。NotionTask#template_differs?(赤塗り判定: テンプレと同じ値なら赤くしない)が
# 参照する「元の値」を提供する。セル値のパースは WbsScheduleCellParser を NotionWbsExcelImporter と共有する。
# シートが読めない場合は空Hashを返す(呼び出し側は「テンプレ行なし」と同じ扱いになる)。
class WbsTemplateValuesReader
  DATA_FIRST_ROW = 8
  DATA_LAST_ROW  = 183
  NAMESPACES     = WbsExcelDocument::NAMESPACES

  Field = Struct.new(:column, :attribute, :kind)
  FIELDS = [
    Field.new("E", :progress_rate, :rate),
    Field.new("F", :workload, :number),
    Field.new("G", :start_date, :date),
    Field.new("H", :end_date, :date)
  ].freeze

  def initialize(workbook_bytes:)
    @workbook_bytes = workbook_bytes
  end

  # { normalized_wbs_level => { progress_rate: Float|nil, workload: Float|nil,
  #                              start_date: Date|nil, end_date: Date|nil } }
  def call
    document = WbsExcelDocument.new(@workbook_bytes)
    return {} if document.sheet_path.nil?

    values_by_wbs_level = {}
    each_data_row(document.sheet_document) do |row_node|
      wbs_level_text = document.cell_text_value(document.find_cell(row_node, "B"))
      next if wbs_level_text.blank?

      wbs_level = WbsExcelDocument.normalize_wbs_level(wbs_level_text)
      values_by_wbs_level[wbs_level] = row_values(document, row_node)
    end
    values_by_wbs_level
  rescue StandardError
    {}
  end

  private

  def each_data_row(sheet_document)
    sheet_document.xpath("//main:sheetData/main:row", NAMESPACES).each do |row_node|
      row_number = row_node["r"].to_i
      next unless row_number.between?(DATA_FIRST_ROW, DATA_LAST_ROW)

      yield row_node
    end
  end

  def row_values(document, row_node)
    FIELDS.to_h do |field|
      cell_text = document.cell_text_value(document.find_cell(row_node, field.column))
      [ field.attribute, WbsScheduleCellParser.parse_cell_value(field.kind, cell_text) ]
    end
  end
end
