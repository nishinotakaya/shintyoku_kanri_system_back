require "test_helper"
require "zip"
require "stringio"

# WbsExcelDocument: zip 展開の上限(zip bomb 対策)を検証する。
class WbsExcelDocumentTest < Minitest::Test
  def test_raises_when_zip_entry_count_exceeds_the_limit
    entry_count = WbsExcelDocument::MAX_ZIP_ENTRIES + 1
    bytes = build_zip_with_many_entries(entry_count)

    error = assert_raises(ArgumentError) { WbsExcelDocument.new(bytes) }
    assert_equal "Excel ファイルが大きすぎます", error.message
  end

  private

  def build_zip_with_many_entries(entry_count)
    buffer = Zip::OutputStream.write_buffer do |zip_output|
      entry_count.times do |index|
        zip_output.put_next_entry("entry_#{index}.txt")
        zip_output.write("x")
      end
    end
    buffer.string
  end
end
