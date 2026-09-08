require "bigdecimal"

# 受領Excel(xlsm)「プロジェクトのスケジュール」シートに Notion(WBS) タスクの実効値を書き込む。
#
# openpyxl 等で保存し直すと条件付き書式の拡張(x14)・図形・calcChain が消えることを実測済みのため、
# zip 内のシート XML の「値セル」だけを Nokogiri で書き換える方式にする（VBA・条件付き書式・
# 定義名・他シートには一切触れない）。
# zip/XML の読み取りは WbsExcelDocument を共有する。
class NotionWbsExcelUpdater
  SHEET_NAME       = WbsExcelDocument::SHEET_NAME
  DATA_FIRST_ROW   = 8
  DATA_LAST_ROW    = 183
  MAIN_NS          = WbsExcelDocument::MAIN_NS
  PACKAGE_RELS_NS  = WbsExcelDocument::PACKAGE_RELS_NS
  CONTENT_TYPES_NS = "http://schemas.openxmlformats.org/package/2006/content-types".freeze
  NAMESPACES       = WbsExcelDocument::NAMESPACES
  EXCEL_EPOCH      = Date.new(1899, 12, 30) # Excel のシリアル値起点(1900年うるう年バグ込み)
  ZENKAKU_SPACE    = "　".freeze
  # 「修正後」の値が未提出、かつ登録済みテンプレの値と異なるセル(NotionTask#red_cell?)に塗る背景色。
  # 提出済にする、またはテンプレと同じ値に戻すと消える。
  RED_FILL_RGB     = "FFFF9999".freeze

  # C〜H 列（B は突合キーなので既存行では上書きしない。新規行では B〜H を書く）
  Column = Struct.new(:letter, :attribute)
  COLUMNS = [
    Column.new("B", :wbs_level),
    Column.new("C", :title),
    Column.new("D", :assignee_name),
    Column.new("E", :progress_rate),
    Column.new("F", :workload),
    Column.new("G", :start_date),
    Column.new("H", :end_date)
  ].freeze

  def initialize(template_bytes:, tasks:)
    @template_bytes = template_bytes
    @tasks = Array(tasks)
  end

  def call
    @document = WbsExcelDocument.new(@template_bytes)
    raise "「#{SHEET_NAME}」シートが見つかりません" if @document.sheet_path.nil?

    entries = @document.entries
    sheet_document = @document.sheet_document
    row_by_wbs_level = index_rows_by_wbs_level(@document)
    template_values_by_wbs_level = WbsTemplateValuesReader.new(workbook_bytes: @template_bytes).call

    matched_count = 0
    appended_count = 0
    skipped_count = 0
    @changed_cell_count = 0
    @unsubmitted_cell_count = 0
    next_append_row = last_filled_row(sheet_document) + 1

    sorted_tasks.each do |task|
      wbs_level = WbsExcelDocument.normalize_wbs_level(task.wbs_level) # 索引側と同じ正規化で突合する(数値セル 1.1 と文字列 "1.1")

      if wbs_level.blank?
        skipped_count += 1 # WBSレベル未設定は行を増やさずスキップする
        next
      end

      row_node = row_by_wbs_level[wbs_level]

      if row_node
        template_row = template_values_by_wbs_level[wbs_level]
        update_matched_row!(sheet_document, row_node, row_node["r"].to_i, task, template_row)
        matched_count += 1
      elsif next_append_row > DATA_LAST_ROW
        skipped_count += 1
      else
        append_row = find_or_build_row(sheet_document, next_append_row)
        write_appended_row!(sheet_document, append_row, next_append_row, task)
        appended_count += 1
        next_append_row += 1
      end
    end

    entries[@document.sheet_path] = sheet_document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    if @document.styles_modified?
      entries["xl/styles.xml"] = @document.styles_document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end
    remove_calc_chain!(entries)
    ensure_full_calc_on_load!(entries)

    { bytes: WbsExcelDocument.write_zip_entries(entries), matched_count: matched_count,
      appended_count: appended_count, skipped_count: skipped_count,
      changed_cell_count: @changed_cell_count, unsubmitted_cell_count: @unsubmitted_cell_count }
  end

  private

  def sorted_tasks
    @tasks.sort_by { |task| task.wbs_level.to_s.split(".").map { |part| part.to_i } }
  end

  # ---- 既存行の索引作成 ----

  def index_rows_by_wbs_level(document)
    index = {}
    each_data_row(document.sheet_document) do |row_node, row_number|
      cell_node = document.find_cell(row_node, "B")
      wbs_level = WbsExcelDocument.normalize_wbs_level(document.cell_text_value(cell_node))
      index[wbs_level] = row_node if wbs_level.present?
    end
    index
  end

  # データ行のうち B〜H のいずれかに値がある最後の行番号（次の空行への追記の起点）
  def last_filled_row(sheet_document)
    last_row = DATA_FIRST_ROW - 1
    each_data_row(sheet_document) do |row_node, row_number|
      has_content = COLUMNS.any? { |column| find_cell(row_node, column.letter)&.content.present? }
      last_row = row_number if has_content
    end
    last_row
  end

  def each_data_row(sheet_document)
    sheet_document.xpath("//main:sheetData/main:row", NAMESPACES).each do |row_node|
      row_number = row_node["r"].to_i
      next unless row_number.between?(DATA_FIRST_ROW, DATA_LAST_ROW)
      yield row_node, row_number
    end
  end

  # ---- セルの検索(行ノード内) ----

  def find_cell(row_node, column_letter)
    row_node.xpath("main:c", NAMESPACES).find { |cell_node| WbsExcelDocument.column_letters_of(cell_node["r"]) == column_letter }
  end

  # ---- 既存行の上書き ----

  # 既存行は「アプリで修正した項目(*_prev がある項目)」だけを書き、それ以外のセルには一切触れない
  # (元ファイルと完全に同じ状態を保つ)。書いたセルのうち NotionTask#red_cell?(未提出、かつ
  # 登録済みテンプレの値と異なる)なものだけ背景を赤く塗る。
  def update_matched_row!(sheet_document, row_node, row_number, task, template_row)
    reference_row = previous_data_row(sheet_document, row_number)

    COLUMNS.each do |column|
      next if column.letter == "B" # 突合キーは変更しない
      next unless task.override_present?(column.attribute) # 修正されていない項目のセルは触らない

      cell_node = find_or_build_cell(sheet_document, row_node, column.letter, row_number, reference_row)
      write_cell!(cell_node, column, task, row_node)
      apply_unsubmitted_fill!(cell_node) if task.red_cell?(column.attribute, template_row)
    end
  end

  # 未提出かつテンプレと異なる「修正後」を反映したセルの背景を赤くする(NotionTask#red_cell?)。
  # 提出済(mark_overrides_submitted!)にする、またはテンプレと同じ値に戻すと塗られなくなる。
  def apply_unsubmitted_fill!(cell_node)
    cell_node["s"] = @document.style_id_with_fill(cell_node["s"], rgb: RED_FILL_RGB)
    @unsubmitted_cell_count += 1
  end

  # ---- 新規行の追加 ----

  def find_or_build_row(sheet_document, row_number)
    existing_row = sheet_document.at_xpath("//main:sheetData/main:row[@r='#{row_number}']", NAMESPACES)
    return existing_row if existing_row

    sheet_data = sheet_document.at_xpath("//main:sheetData", NAMESPACES)
    new_row = Nokogiri::XML::Node.new("row", sheet_document)
    new_row["r"] = row_number.to_s
    insert_row_in_order(sheet_data, new_row, row_number)
    new_row
  end

  def insert_row_in_order(sheet_data, new_row, row_number)
    following_row = sheet_data.xpath("main:row", NAMESPACES).find { |row_node| row_node["r"].to_i > row_number }
    if following_row
      following_row.add_previous_sibling(new_row)
    else
      sheet_data.add_child(new_row)
    end
  end

  def write_appended_row!(sheet_document, row_node, row_number, task)
    reference_row = previous_data_row(sheet_document, row_number)

    COLUMNS.each do |column|
      cell_node = find_or_build_cell(sheet_document, row_node, column.letter, row_number, reference_row)
      write_cell!(cell_node, column, task, row_node)
    end
  end

  # 行内に指定列のセルが無ければ、列順を保って生成し、直前のデータ行の同列からスタイルを継承する。
  # update_matched_row!(既存行の欠損セル補完)と write_appended_row!(新規行)の両方から使う。
  def find_or_build_cell(sheet_document, row_node, column_letter, row_number, reference_row)
    cell_node = find_cell(row_node, column_letter)
    return cell_node if cell_node

    cell_node = Nokogiri::XML::Node.new("c", sheet_document)
    cell_node["r"] = "#{column_letter}#{row_number}"
    insert_cell_in_order(row_node, cell_node, column_letter)

    style = reference_row && find_cell(reference_row, column_letter)&.attribute("s")&.value
    cell_node["s"] = style if style

    cell_node
  end

  def insert_cell_in_order(row_node, new_cell, column_letter)
    target_index = column_index(column_letter)
    following_cell = row_node.xpath("main:c", NAMESPACES).find { |cell_node| column_index(WbsExcelDocument.column_letters_of(cell_node["r"])) > target_index }
    if following_cell
      following_cell.add_previous_sibling(new_cell)
    else
      row_node.add_child(new_cell)
    end
  end

  def column_index(column_letter)
    column_letter.to_s.each_char.reduce(0) { |sum, char| sum * 26 + (char.ord - "A".ord + 1) }
  end

  def previous_data_row(sheet_document, row_number)
    candidate = nil
    each_data_row(sheet_document) do |row_node, number|
      candidate = row_node if number < row_number
    end
    candidate
  end

  # ---- セルへの書き込み ----

  def write_cell!(cell_node, column, task, row_node)
    value = column.attribute == :wbs_level ? task.wbs_level : task.public_send("effective_#{column.attribute}")
    @changed_cell_count += 1

    case column.attribute
    when :wbs_level, :assignee_name
      write_text_cell!(cell_node, value)
    when :title
      write_title_cell!(cell_node, value, task, row_node)
    when :progress_rate, :workload
      write_number_cell!(cell_node, value)
    when :start_date, :end_date
      write_number_cell!(cell_node, value && excel_serial(value))
    end
  end

  def write_title_cell!(cell_node, title, task, row_node)
    if title.blank?
      clear_cell!(cell_node)
      return
    end

    write_text_cell!(cell_node, "#{indent_for(cell_node, task)}#{title}")
  end

  def indent_for(cell_node, task)
    existing_text = cell_node.at_xpath("main:is/main:t", NAMESPACES)&.text ||
      cell_node.at_xpath("main:v", NAMESPACES)&.text
    existing_indent = existing_text.to_s[/\A#{ZENKAKU_SPACE}+/]
    return existing_indent if existing_indent.present?

    segment_count = task.wbs_level.to_s.split(".").size
    ZENKAKU_SPACE * [ segment_count - 2, 1 ].max
  end

  def write_text_cell!(cell_node, text)
    if text.blank?
      clear_cell!(cell_node)
      return
    end

    cell_node.children.remove
    cell_node["t"] = "inlineStr"
    is_node = Nokogiri::XML::Node.new("is", cell_node.document)
    t_node = Nokogiri::XML::Node.new("t", cell_node.document)
    t_node["xml:space"] = "preserve"
    t_node.content = text.to_s
    is_node.add_child(t_node)
    cell_node.add_child(is_node)
  end

  def write_number_cell!(cell_node, value)
    if value.nil?
      clear_cell!(cell_node)
      return
    end

    cell_node.children.remove
    cell_node.remove_attribute("t")
    v_node = Nokogiri::XML::Node.new("v", cell_node.document)
    v_node.content = format_numeric(value)
    cell_node.add_child(v_node)
  end

  def clear_cell!(cell_node)
    cell_node.children.remove
    cell_node.remove_attribute("t")
  end

  def format_numeric(value)
    decimal_value = BigDecimal(value.to_s)
    decimal_value == decimal_value.to_i ? decimal_value.to_i.to_s : decimal_value.to_s("F")
  end

  def excel_serial(date)
    (date - EXCEL_EPOCH).to_i
  end

  # ---- calcChain / 再計算フラグ ----

  def remove_calc_chain!(entries)
    return unless entries.key?("xl/calcChain.xml")

    entries.delete("xl/calcChain.xml")
    remove_calc_chain_from_content_types!(entries)
    remove_calc_chain_from_workbook_rels!(entries)
  end

  def remove_calc_chain_from_content_types!(entries)
    document = WbsExcelDocument.parse_xml(entries.fetch("[Content_Types].xml"))
    override = document.at_xpath("//xmlns:Override[@PartName='/xl/calcChain.xml']", "xmlns" => CONTENT_TYPES_NS)
    override&.remove
    entries["[Content_Types].xml"] = document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
  end

  def remove_calc_chain_from_workbook_rels!(entries)
    document = WbsExcelDocument.parse_xml(entries.fetch("xl/_rels/workbook.xml.rels"))
    relationship = document.at_xpath("//xmlns:Relationship[contains(@Target, 'calcChain.xml')]",
      "xmlns" => PACKAGE_RELS_NS)
    relationship&.remove
    entries["xl/_rels/workbook.xml.rels"] = document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
  end

  def ensure_full_calc_on_load!(entries)
    document = WbsExcelDocument.parse_xml(entries.fetch("xl/workbook.xml"))
    calc_pr = document.at_xpath("//main:calcPr", NAMESPACES)
    if calc_pr.nil?
      calc_pr = Nokogiri::XML::Node.new("calcPr", document)
      document.at_xpath("//main:workbook", NAMESPACES).add_child(calc_pr)
    end
    calc_pr["fullCalcOnLoad"] = "1"
    entries["xl/workbook.xml"] = document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
  end
end
