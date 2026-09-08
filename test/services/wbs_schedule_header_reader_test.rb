require "test_helper"
require "zip"
require "stringio"

# WbsScheduleHeaderReader: 受領Excel(xlsm)「プロジェクトのスケジュール」シートの
# B1(プロジェクト名)/B2(会社名)/G3(開始日シリアル値)を読む。
class WbsScheduleHeaderReaderTest < Minitest::Test
  TEMPLATE_PATH = Rails.root.join("test/fixtures/files/wbs_schedule_template.xlsm")

  def setup
    @template_bytes = File.binread(TEMPLATE_PATH)
  end

  def test_reads_project_title_company_name_and_project_start
    header = WbsScheduleHeaderReader.new(@template_bytes).call

    assert_equal "WBS（フェーズ1：現行機能の刷新）", header[:project_title]
    assert_equal "ダミー会社", header[:company_name]
    assert_equal "2026-08-10", header[:project_start]
  end

  # G3 が数値でない場合、to_i の黙った 0 変換(1899年化)ではなく nil を返す
  def test_returns_nil_project_start_when_g3_is_not_numeric
    bytes = replace_g3_cell(@template_bytes, '<c r="G3" s="43" t="inlineStr"><is><t>未定</t></is></c>')

    header = WbsScheduleHeaderReader.new(bytes).call

    assert_nil header[:project_start]
  end

  # G3 が Excel の有効な日付シリアル範囲(1〜2,958,465)を外れている場合も nil を返す
  def test_returns_nil_project_start_when_g3_is_out_of_valid_serial_range
    bytes = replace_g3_cell(@template_bytes, '<c r="G3" s="43"><v>99999999</v></c>')

    header = WbsScheduleHeaderReader.new(bytes).call

    assert_nil header[:project_start]
  end

  private

  def replace_g3_cell(bytes, replacement_xml)
    entries = {}
    Zip::File.open_buffer(StringIO.new(bytes)) { |zip_file| zip_file.each { |entry| entries[entry.name] = entry.get_input_stream.read } }
    entries["xl/worksheets/sheet2.xml"] = entries.fetch("xl/worksheets/sheet2.xml").dup.force_encoding("UTF-8")
      .sub(/<c r="G3"[^>]*\/>|<c r="G3"[^>]*>.*?<\/c>/, replacement_xml)

    buffer = Zip::OutputStream.write_buffer do |zip_output|
      entries.each do |name, content|
        zip_output.put_next_entry(name)
        zip_output.write(content)
      end
    end
    buffer.string
  end
end
