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
