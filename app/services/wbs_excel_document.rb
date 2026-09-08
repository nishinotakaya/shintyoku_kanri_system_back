require "zip"
require "stringio"

# 受領Excel(xlsm)の zip 構造から「プロジェクトのスケジュール」シートの XML と共有文字列を取り出す
# 共通ヘルパー。NotionWbsExcelUpdater(値の書き込み)と WbsExcelTemplate(ヘッダ情報の読み取り)で
# zip/XML の読み書きロジックを重複させないために使う。
class WbsExcelDocument
  SHEET_NAME       = "プロジェクトのスケジュール".freeze
  MAIN_NS          = "http://schemas.openxmlformats.org/spreadsheetml/2006/main".freeze
  RELATIONSHIPS_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships".freeze
  PACKAGE_RELS_NS  = "http://schemas.openxmlformats.org/package/2006/relationships".freeze
  NAMESPACES       = { "main" => MAIN_NS, "r" => RELATIONSHIPS_NS }.freeze

  # zip 展開の上限(zip bomb 対策)。エントリ数・展開後合計サイズのどちらかを超えたら読み込みを中止する。
  MAX_ZIP_ENTRIES               = 5_000
  MAX_TOTAL_UNCOMPRESSED_BYTES  = 200 * 1024 * 1024

  attr_reader :entries

  def initialize(bytes)
    @entries = self.class.read_zip_entries(bytes)
  end

  def sheet_path
    return @sheet_path if defined?(@sheet_path)

    @sheet_path = resolve_sheet_path
  end

  def sheet_document
    return @sheet_document if defined?(@sheet_document)

    xml = sheet_path && entries[sheet_path]
    @sheet_document = xml && self.class.parse_xml(xml)
  end

  def shared_strings
    @shared_strings ||= load_shared_strings
  end

  # xl/styles.xml の Nokogiri::XML::Document(遅延読み込み)。style_id_with_fill が書き換える。
  def styles_document
    return @styles_document if defined?(@styles_document)

    xml = entries["xl/styles.xml"]
    @styles_document = xml && self.class.parse_xml(xml)
  end

  # style_id_with_fill で styles_document に変更が入っていれば true(呼び出し側が entries へ書き戻す判断に使う)。
  def styles_modified?
    @styles_modified == true
  end

  # base_style_id(元セルの s 属性。無い場合は nil) を「rgb で塗り潰す」バリエーションに複製した新しい
  # スタイル index(文字列)を返す。fills/cellXfs への追加は (base_style_id, rgb) の組ごとに1回だけ行う。
  def style_id_with_fill(base_style_id, rgb:)
    @style_id_with_fill_cache ||= {}
    cache_key = [ base_style_id, rgb ]
    return @style_id_with_fill_cache[cache_key] if @style_id_with_fill_cache.key?(cache_key)

    fill_id = fill_id_for(rgb)
    new_style_id = append_cell_xf_with_fill(base_style_id, fill_id).to_s
    @style_id_with_fill_cache[cache_key] = new_style_id
  end

  # 行ノード内から指定した列(例: "B")のセルノードを探す。
  def find_cell(row_node, column_letter)
    row_node.xpath("main:c", NAMESPACES).find { |cell_node| self.class.column_letters_of(cell_node["r"]) == column_letter }
  end

  # セル参照(例: "B1")のノードを探す。
  def cell_at(cell_reference)
    return nil if sheet_document.nil?

    sheet_document.at_xpath("//main:c[@r='#{cell_reference}']", NAMESPACES)
  end

  # セルの文字列/数値を解決する(t="s"/"inlineStr"/"str"/数値のいずれにも対応)。
  def cell_text_value(cell_node)
    return nil if cell_node.nil?

    case cell_node["t"]
    when "s"
      index = cell_node.at_xpath("main:v", NAMESPACES)&.text
      index.nil? ? nil : shared_strings[index.to_i]
    when "inlineStr"
      cell_node.at_xpath("main:is/main:t", NAMESPACES)&.text
    when "str"
      cell_node.at_xpath("main:v", NAMESPACES)&.text
    else
      cell_node.at_xpath("main:v", NAMESPACES)&.text
    end
  end

  def self.column_letters_of(cell_reference)
    cell_reference.to_s[/\A[A-Z]+/]
  end

  # WBSレベル(B列)の突合キーを揃える(数値セル 1.1 と文字列 "1.1" を同一視する)。
  # NotionWbsExcelUpdater(書き出し)と NotionWbsExcelImporter(取込)の両方で使う。
  def self.normalize_wbs_level(text)
    return nil if text.blank?

    stripped = text.to_s.strip
    Float(stripped)
    format("%g", stripped.to_f)
  rescue ArgumentError, TypeError
    stripped
  end

  def self.read_zip_entries(bytes)
    entries = {}
    entry_count = 0
    total_uncompressed_bytes = 0
    Zip::File.open_buffer(StringIO.new(bytes)) do |zip_file|
      zip_file.each do |entry|
        entry_count += 1
        total_uncompressed_bytes += entry.size
        if entry_count > MAX_ZIP_ENTRIES || total_uncompressed_bytes > MAX_TOTAL_UNCOMPRESSED_BYTES
          raise ArgumentError, "Excel ファイルが大きすぎます"
        end

        entries[entry.name] = entry.get_input_stream.read
      end
    end
    entries
  end

  def self.write_zip_entries(entries)
    ordered_names = ([ "[Content_Types].xml" ] + entries.keys).uniq & entries.keys
    buffer = Zip::OutputStream.write_buffer do |zip_output|
      ordered_names.each do |name|
        zip_output.put_next_entry(name)
        zip_output.write(entries[name])
      end
    end
    buffer.string
  end

  # 外部実体参照・ネットワークアクセスを禁止した厳格モードで XML を読む。壊れた XML は例外を投げる。
  def self.parse_xml(xml)
    Nokogiri::XML(xml) { |config| config.strict.nonet }
  end

  private

  # rgb の solid fill を xl/styles.xml の <fills> に追加し、その index(0始まり)を返す。
  # 同じ rgb での呼び出しは追加せず既存の index を再利用する。
  def fill_id_for(rgb)
    @fill_id_by_rgb ||= {}
    return @fill_id_by_rgb[rgb] if @fill_id_by_rgb.key?(rgb)

    fills_node = styles_document.at_xpath("//main:fills", NAMESPACES)
    new_fill_index = fills_node["count"].to_i

    fill_node = Nokogiri::XML::Node.new("fill", styles_document)
    pattern_fill_node = Nokogiri::XML::Node.new("patternFill", styles_document)
    pattern_fill_node["patternType"] = "solid"
    fg_color_node = Nokogiri::XML::Node.new("fgColor", styles_document)
    fg_color_node["rgb"] = rgb
    bg_color_node = Nokogiri::XML::Node.new("bgColor", styles_document)
    bg_color_node["indexed"] = "64"
    pattern_fill_node.add_child(fg_color_node)
    pattern_fill_node.add_child(bg_color_node)
    fill_node.add_child(pattern_fill_node)
    fills_node.add_child(fill_node)
    fills_node["count"] = (new_fill_index + 1).to_s

    @styles_modified = true
    @fill_id_by_rgb[rgb] = new_fill_index
  end

  # base_style_id(cellXfs の既存 index、無ければ最小限の xf)を fill_id で塗り潰すよう複製し、
  # <cellXfs> に追加した新しい index(0始まり)を返す。
  def append_cell_xf_with_fill(base_style_id, fill_id)
    cell_xfs_node = styles_document.at_xpath("//main:cellXfs", NAMESPACES)
    base_xf_node = base_style_id.present? ? cell_xfs_node.xpath("main:xf", NAMESPACES)[base_style_id.to_i] : nil

    new_xf_node = base_xf_node ? base_xf_node.dup : Nokogiri::XML::Node.new("xf", styles_document)
    new_xf_node["fillId"] = fill_id.to_s
    new_xf_node["applyFill"] = "1"

    new_xf_index = cell_xfs_node["count"].to_i
    cell_xfs_node.add_child(new_xf_node)
    cell_xfs_node["count"] = (new_xf_index + 1).to_s

    @styles_modified = true
    new_xf_index
  end

  def resolve_sheet_path
    return nil unless entries.key?("xl/workbook.xml") && entries.key?("xl/_rels/workbook.xml.rels")

    workbook_document = self.class.parse_xml(entries.fetch("xl/workbook.xml"))
    sheet_element = workbook_document.at_xpath("//main:sheets/main:sheet[@name='#{SHEET_NAME}']", NAMESPACES)
    return nil if sheet_element.nil?

    relationship_id = sheet_element.attribute_with_ns("id", RELATIONSHIPS_NS)&.value
    return nil if relationship_id.nil?

    rels_document = self.class.parse_xml(entries.fetch("xl/_rels/workbook.xml.rels"))
    relationship = rels_document.at_xpath("//xmlns:Relationship[@Id='#{relationship_id}']",
      "xmlns" => PACKAGE_RELS_NS)
    return nil if relationship.nil?

    target = relationship["Target"]
    target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
  end

  def load_shared_strings
    xml = entries["xl/sharedStrings.xml"]
    return [] if xml.nil?

    document = self.class.parse_xml(xml)
    document.xpath("//main:si", NAMESPACES).map do |si_node|
      si_node.xpath(".//main:t", NAMESPACES).map(&:text).join
    end
  end
end
