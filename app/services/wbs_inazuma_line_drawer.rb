# 受領Excel(xlsm)「プロジェクトのスケジュール」のガント上に引く「イナズマ線」を、
# 出力時にサーバー側で描き直す。
#
# 元ファイルの VBA(Module1.DrawInazumaLine)は Workbook_Open で同じ線を引き直すが、
# ダウンロードしたファイルはマクロがブロックされて開かれることが多く、その場合は
# テンプレ保存時の古い線(古い日付・古い基準日)が表に残ったままになる。
# ここで VBA と同じ判定ロジックで点を決め、同じ図形(赤 2pt の直線コネクタ)を
# シートの描画パーツ(xl/drawings/drawingN.xml)に置き換えておく。マクロが有効なら
# VBA が既存線を削除して引き直すので、二重に描かれることはない。
#
# 点の決定ロジック(VBA と同じ順序で判定する):
#   ① 開始日・終了日とも空欄                 → 基準日(今日)
#   ② 終了日 < 基準日 かつ 進捗率 = 100%      → 基準日
#   ③ 終了日 < ガント開始日 かつ 進捗率 > 0% → ガント開始日
#   ④ 開始日 > 基準日 かつ 進捗率 = 0%       → 基準日
#   ⑤ それ以外                              → 開始日 + (終了日 - 開始日) × 進捗率
#   最後に、ガント開始日より前なら ガント開始日 に補正する。
class WbsInazumaLineDrawer
  MAIN_NS    = WbsExcelDocument::MAIN_NS
  NAMESPACES = WbsExcelDocument::NAMESPACES
  DRAWING_NS = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing".freeze
  DML_NS     = "http://schemas.openxmlformats.org/drawingml/2006/main".freeze
  RELS_NS    = WbsExcelDocument::PACKAGE_RELS_NS
  DRAWING_RELATIONSHIP_TYPE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing".freeze
  DRAWING_NAMESPACES = { "xdr" => DRAWING_NS, "a" => DML_NS }.freeze

  EXCEL_EPOCH = WbsScheduleCellParser::EXCEL_EPOCH

  # VBA の定数と同じ
  HEADER_ROW     = 5   # 日付行
  GANTT_START_COLUMN = 11 # ガント開始列(K)
  TASK_START_ROW = 8
  TASK_COLUMN     = "C"
  PROGRESS_COLUMN = "E"
  START_COLUMN    = "G"
  END_COLUMN      = "H"

  # VBA の DeleteInazumaLines が消す範囲(8行目以降・I列以降にある線)
  DELETE_FROM_ROW_INDEX    = TASK_START_ROW - 1 # 0始まり
  DELETE_FROM_COLUMN_INDEX = 8                  # I列(0始まり)

  EMU_PER_POINT = 12_700
  # 列幅(文字数)→ポイント換算。テンプレ(游ゴシック 11pt)で 2.42578125 文字 = 17pt と実測(≒7pt/文字)。
  POINTS_PER_CHARACTER_WIDTH = 7.0
  DEFAULT_ROW_HEIGHT_POINTS  = 15.0
  DEFAULT_COLUMN_WIDTH_CHARS = 8.43

  LINE_COLOR_RGB    = "FF0000".freeze
  LINE_WIDTH_EMU    = 25_400 # 2pt
  LINE_NAME_PREFIX  = "直線コネクタ".freeze

  Point = Struct.new(:column_number, :row_number)

  def initialize(document:, base_date:)
    @document = document
    @base_date = base_date
  end

  # 描画パーツを書き換え、引いた線分の数を返す。描画パーツが無いシートでは何もせず 0 を返す。
  def call
    drawing_path = resolve_drawing_path
    return 0 if drawing_path.nil? || @document.entries[drawing_path].nil?

    drawing_document = WbsExcelDocument.parse_xml(@document.entries[drawing_path])
    points = collect_points
    remove_existing_lines!(drawing_document)
    segment_count = append_lines!(drawing_document, points)

    @document.entries[drawing_path] = drawing_document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    segment_count
  end

  private

  # ---- 点の決定 ----

  def collect_points
    gantt_dates = header_dates
    return [] if gantt_dates.empty?

    gantt_start_serial = gantt_dates.first
    points = []
    each_task_row do |row_node, row_number|
      point_serial = point_serial_for(row_node, gantt_start_serial)
      point_serial = gantt_start_serial if point_serial < gantt_start_serial
      column_number = date_column_for(gantt_dates, point_serial)
      points << Point.new(column_number, row_number)
    end
    points
  end

  # 5行目 K列から右へ、日付(数値)が入っている限り読む(VBA の FindDateColumn の走査範囲)。
  def header_dates
    row_node = row_at(HEADER_ROW)
    return [] if row_node.nil?

    dates = []
    column_number = GANTT_START_COLUMN
    loop do
      cell_node = @document.find_cell(row_node, column_letter(column_number))
      serial = Float(@document.cell_text_value(cell_node).to_s, exception: false)
      break if serial.nil?

      dates << serial
      column_number += 1
    end
    dates
  end

  # 8行目から、タスク名(C列)が空の行に当たるまで(VBA と同じ終了条件)。
  def each_task_row
    sheet_document = @document.sheet_document
    row_number = TASK_START_ROW
    loop do
      row_node = sheet_document.at_xpath("//main:sheetData/main:row[@r='#{row_number}']", NAMESPACES)
      break if row_node.nil?
      break if @document.cell_text_value(@document.find_cell(row_node, TASK_COLUMN)).blank?

      yield row_node, row_number
      row_number += 1
    end
  end

  def point_serial_for(row_node, gantt_start_serial)
    base_serial = (@base_date - EXCEL_EPOCH).to_i
    start_serial = date_serial(row_node, START_COLUMN)
    end_serial   = date_serial(row_node, END_COLUMN)
    progress = progress_rate(row_node)

    if start_serial.nil? && end_serial.nil?
      base_serial
    elsif end_serial && end_serial < base_serial && progress >= 1
      base_serial
    elsif end_serial && end_serial < gantt_start_serial && progress > 0
      gantt_start_serial
    elsif start_serial && start_serial > base_serial && progress <= 0
      base_serial
    else
      # VBA の CDate(Empty) は 0 (1899-12-30) になるので、片方が空欄でも同じ算術で扱う
      (start_serial || 0) + ((end_serial || 0) - (start_serial || 0)) * progress
    end
  end

  def date_serial(row_node, column_letter)
    date = WbsScheduleCellParser.parse_date_cell(@document.cell_text_value(@document.find_cell(row_node, column_letter)))
    date && (date - EXCEL_EPOCH).to_i
  end

  def progress_rate(row_node)
    value = Float(@document.cell_text_value(@document.find_cell(row_node, PROGRESS_COLUMN)).to_s, exception: false)
    (value || 0.0).clamp(0.0, 1.0)
  end

  # 日付行で point_serial 以上になる最初の列。無ければガント開始列(VBA と同じ)。
  def date_column_for(gantt_dates, point_serial)
    index = gantt_dates.index { |serial| serial >= point_serial }
    index ? GANTT_START_COLUMN + index : GANTT_START_COLUMN
  end

  # ---- 図形の削除・追加 ----

  # ガント領域(8行目以降・I列以降)にある直線を消す(VBA の DeleteInazumaLines と同じ範囲)。
  def remove_existing_lines!(drawing_document)
    drawing_document.xpath("//xdr:twoCellAnchor[xdr:cxnSp]", DRAWING_NAMESPACES).each do |anchor_node|
      from_node = anchor_node.at_xpath("xdr:from", DRAWING_NAMESPACES)
      next if from_node.nil?

      from_row    = from_node.at_xpath("xdr:row", DRAWING_NAMESPACES)&.text.to_i
      from_column = from_node.at_xpath("xdr:col", DRAWING_NAMESPACES)&.text.to_i
      anchor_node.remove if from_row >= DELETE_FROM_ROW_INDEX && from_column >= DELETE_FROM_COLUMN_INDEX
    end
  end

  def append_lines!(drawing_document, points)
    root_node = drawing_document.root
    next_shape_id = max_shape_id(drawing_document) + 1
    segment_count = 0

    points.each_cons(2) do |previous_point, current_point|
      root_node.add_child(build_line_anchor(drawing_document, previous_point, current_point, next_shape_id))
      next_shape_id += 1
      segment_count += 1
    end
    segment_count
  end

  def max_shape_id(drawing_document)
    drawing_document.xpath("//xdr:cNvPr/@id", DRAWING_NAMESPACES).map { |attribute| attribute.value.to_i }.max || 0
  end

  # 2つのセル中心を結ぶ直線を twoCellAnchor で組む。行は常に下向き(from < to)。
  # 左上→右下 でなく 右上→左下 に向かう線は、from/to を左右入れ替えて flipH で表す(Excel と同じ表現)。
  def build_line_anchor(drawing_document, previous_point, current_point, shape_id)
    left_point, right_point, flipped = if current_point.column_number >= previous_point.column_number
      [ previous_point, current_point, false ]
    else
      [ current_point, previous_point, true ]
    end
    from_column = left_point.column_number
    to_column   = right_point.column_number
    from_row    = previous_point.row_number
    to_row      = current_point.row_number

    from_x = column_left_emu(from_column) + column_width_emu(from_column) / 2
    to_x   = column_left_emu(to_column) + column_width_emu(to_column) / 2
    from_y = row_top_emu(from_row) + row_height_emu(from_row) / 2
    to_y   = row_top_emu(to_row) + row_height_emu(to_row) / 2

    xml = <<~XML
      <xdr:twoCellAnchor xmlns:xdr="#{DRAWING_NS}" xmlns:a="#{DML_NS}">
        <xdr:from><xdr:col>#{from_column - 1}</xdr:col><xdr:colOff>#{column_width_emu(from_column) / 2}</xdr:colOff><xdr:row>#{from_row - 1}</xdr:row><xdr:rowOff>#{row_height_emu(from_row) / 2}</xdr:rowOff></xdr:from>
        <xdr:to><xdr:col>#{to_column - 1}</xdr:col><xdr:colOff>#{column_width_emu(to_column) / 2}</xdr:colOff><xdr:row>#{to_row - 1}</xdr:row><xdr:rowOff>#{row_height_emu(to_row) / 2}</xdr:rowOff></xdr:to>
        <xdr:cxnSp macro="">
          <xdr:nvCxnSpPr><xdr:cNvPr id="#{shape_id}" name="#{LINE_NAME_PREFIX} #{shape_id}"/><xdr:cNvCxnSpPr/></xdr:nvCxnSpPr>
          <xdr:spPr>
            <a:xfrm#{flipped ? ' flipH="1"' : ''}><a:off x="#{from_x}" y="#{from_y}"/><a:ext cx="#{to_x - from_x}" cy="#{to_y - from_y}"/></a:xfrm>
            <a:prstGeom prst="line"><a:avLst/></a:prstGeom>
            <a:ln w="#{LINE_WIDTH_EMU}"><a:solidFill><a:srgbClr val="#{LINE_COLOR_RGB}"/></a:solidFill></a:ln>
          </xdr:spPr>
          <xdr:style>
            <a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="0"><a:schemeClr val="accent1"/></a:fillRef>
            <a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="tx1"/></a:fontRef>
          </xdr:style>
        </xdr:cxnSp>
        <xdr:clientData/>
      </xdr:twoCellAnchor>
    XML
    fragment = Nokogiri::XML::DocumentFragment.new(drawing_document, xml, drawing_document.root)
    fragment.children.find(&:element?)
  end

  # ---- シートの寸法(twoCellAnchor のオフセット計算用) ----

  def column_width_emu(column_number)
    (column_width_chars(column_number) * POINTS_PER_CHARACTER_WIDTH * EMU_PER_POINT).round
  end

  def column_left_emu(column_number)
    (1...column_number).sum { |number| column_width_emu(number) }
  end

  def column_width_chars(column_number)
    definition = column_definitions.find { |range, _width| range.cover?(column_number) }
    definition ? definition.last : default_column_width_chars
  end

  # <cols> の (min..max) => 幅(文字数)。hidden 列は幅 0。
  def column_definitions
    @column_definitions ||= @document.sheet_document.xpath("//main:cols/main:col", NAMESPACES).map do |col_node|
      width = col_node["hidden"] == "1" ? 0.0 : Float(col_node["width"].to_s, exception: false) || default_column_width_chars
      [ (col_node["min"].to_i..col_node["max"].to_i), width ]
    end
  end

  def default_column_width_chars
    @default_column_width_chars ||= Float(sheet_format_pr&.[]("defaultColWidth").to_s, exception: false) || DEFAULT_COLUMN_WIDTH_CHARS
  end

  def row_height_emu(row_number)
    (row_height_points(row_number) * EMU_PER_POINT).round
  end

  def row_top_emu(row_number)
    (1...row_number).sum { |number| row_height_emu(number) }
  end

  def row_height_points(row_number)
    @row_heights ||= {}
    @row_heights[row_number] ||= begin
      row_node = row_at(row_number)
      height = row_node && Float(row_node["ht"].to_s, exception: false)
      height || default_row_height_points
    end
  end

  def default_row_height_points
    @default_row_height_points ||= Float(sheet_format_pr&.[]("defaultRowHeight").to_s, exception: false) || DEFAULT_ROW_HEIGHT_POINTS
  end

  def sheet_format_pr
    @document.sheet_document.at_xpath("//main:sheetFormatPr", NAMESPACES)
  end

  def row_at(row_number)
    @document.sheet_document.at_xpath("//main:sheetData/main:row[@r='#{row_number}']", NAMESPACES)
  end

  def column_letter(column_number)
    letters = +""
    number = column_number
    while number > 0
      number, remainder = (number - 1).divmod(26)
      letters.prepend((65 + remainder).chr)
    end
    letters
  end

  # ---- 描画パーツの解決 ----

  # シートの rels から drawing の Target(例: ../drawings/drawing1.xml)を zip 内パスに解決する。
  def resolve_drawing_path
    sheet_path = @document.sheet_path
    return nil if sheet_path.nil?

    rels_path = "#{File.dirname(sheet_path)}/_rels/#{File.basename(sheet_path)}.rels"
    rels_xml = @document.entries[rels_path]
    return nil if rels_xml.nil?

    rels_document = WbsExcelDocument.parse_xml(rels_xml)
    relationship = rels_document.at_xpath("//xmlns:Relationship[@Type='#{DRAWING_RELATIONSHIP_TYPE}']", "xmlns" => RELS_NS)
    return nil if relationship.nil?

    target = relationship["Target"].to_s
    return target.delete_prefix("/") if target.start_with?("/")

    File.expand_path(target, "/#{File.dirname(sheet_path)}").delete_prefix("/")
  end
end
