require "test_helper"

# WbsTemplateValuesReader: 登録済みテンプレ(xlsm)「プロジェクトのスケジュール」シートの
# E〜H列(進捗率・工数・開始日・終了日)をWBSレベルごとに読み取る。
class WbsTemplateValuesReaderTest < Minitest::Test
  TEMPLATE_PATH = Rails.root.join("test/fixtures/files/wbs_schedule_template.xlsm")

  def setup
    @template_bytes = File.binread(TEMPLATE_PATH)
  end

  # 行9(1.1)〜行12(2.1.1)の値がWBSレベルをキーに取れる
  def test_reads_progress_rate_workload_and_dates_by_wbs_level
    values_by_wbs_level = WbsTemplateValuesReader.new(workbook_bytes: @template_bytes).call

    assert_equal(
      { progress_rate: 0.5, workload: 2.0, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 10) },
      values_by_wbs_level["1.1"]
    )
    assert_equal(
      { progress_rate: 1.0, workload: 3.0, start_date: Date.new(2026, 9, 5), end_date: Date.new(2026, 9, 7) },
      values_by_wbs_level["1.2"]
    )
    assert_equal(
      { progress_rate: 0.0, workload: 1.0, start_date: Date.new(2026, 9, 15), end_date: Date.new(2026, 9, 20) },
      values_by_wbs_level["2.1.1"]
    )
  end

  # B列が空の見出し行(8行目「設計」等)は索引に含まれない
  def test_does_not_index_rows_without_a_wbs_level
    values_by_wbs_level = WbsTemplateValuesReader.new(workbook_bytes: @template_bytes).call

    assert_equal 3, values_by_wbs_level.size
  end

  # 「プロジェクトのスケジュール」シートが無い(壊れた)ファイルは例外を出さず空Hashを返す
  def test_returns_empty_hash_when_sheet_is_missing
    values_by_wbs_level = WbsTemplateValuesReader.new(workbook_bytes: "not a zip".b).call

    assert_equal({}, values_by_wbs_level)
  end
end
