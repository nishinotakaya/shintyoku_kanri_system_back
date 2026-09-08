require "test_helper"
require "zip"
require "stringio"

# NotionWbsExcelImporter: ISN(川村さん)が編集した進捗報告書Excel(.xlsx/.xlsm)
# 「プロジェクトのスケジュール」シートを読み、アプリの元の値(Notion同期値)と異なるセルだけを
# NotionTask の *_prev(修正後)に反映する。アップロードされたExcelを正として扱うため、
# シートの値が元の値と同じなら既存の *_prev はクリアする。
class NotionWbsExcelImporterTest < Minitest::Test
  TEMPLATE_PATH = Rails.root.join("test/fixtures/files/wbs_schedule_template.xlsm")

  def setup
    @template_bytes = File.binread(TEMPLATE_PATH)
    @notion_tasks = []
  end

  def teardown
    @notion_tasks.each(&:destroy)
  end

  # 行9(1.1)は E=0.5 F=2 G=2026-09-01 H=2026-09-10。全項目が一致するタスクは何も変わらない。
  # 行10(1.2)・行12(2.1.1)は対応するタスクが無いので unmatched に数える。
  def test_matching_row_with_identical_values_does_not_change_anything
    task = create_task(wbs_level: "1.1", progress_rate: 0.5, workload: 2,
                        start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 10))

    result = call_importer([ task ])
    task.reload

    assert_nil task.progress_rate_prev
    assert_nil task.workload_prev
    assert_nil task.start_date_prev
    assert_nil task.end_date_prev
    assert_equal 0, result[:applied_task_count]
    assert_equal 0, result[:applied_cell_count]
    assert_equal 0, result[:cleared_cell_count]
    assert_equal 1, result[:unchanged_row_count]
    assert_equal 2, result[:unmatched_row_count]
  end

  # 開始日だけシートの値(2026-09-01)がタスクの元の値(2026-09-05)と異なる行は start_date_prev だけ入る
  def test_row_with_only_start_date_difference_sets_only_start_date_prev
    task = create_task(wbs_level: "1.1", progress_rate: 0.5, workload: 2,
                        start_date: Date.new(2026, 9, 5), end_date: Date.new(2026, 9, 10))

    result = call_importer([ task ])
    task.reload

    assert_equal Date.new(2026, 9, 1), task.start_date_prev
    assert_nil task.end_date_prev
    assert_nil task.progress_rate_prev
    assert_nil task.workload_prev
    assert_equal 1, result[:applied_task_count]
    assert_equal 1, result[:applied_cell_count]
    assert_equal 0, result[:cleared_cell_count]
  end

  # 1(整数相当)と 1.0(小数)の差は変更扱いにならない(F9のシート値="2"、タスク側は Float 2.0)
  def test_integer_and_float_workload_are_treated_as_equal
    task = create_task(wbs_level: "1.1", progress_rate: 0.5, workload: 2.0,
                        start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 10))

    result = call_importer([ task ])
    task.reload

    assert_nil task.workload_prev
    assert_equal 0, result[:applied_cell_count]
    assert_equal 0, result[:cleared_cell_count]
    assert_equal 1, result[:unchanged_row_count]
  end

  # アプリ側に該当するWBSレベルのタスクが1件も無ければ、シートの全データ行(1.1/1.2/2.1.1)が unmatched
  def test_rows_without_a_matching_task_count_as_unmatched
    result = call_importer([])

    assert_equal 3, result[:unmatched_row_count]
    assert_equal 0, result[:applied_task_count]
    assert_equal 0, result[:unchanged_row_count]
  end

  # 空セル(G9を削除)は「変更なし」として扱われ、タスク側の値と異なっていても上書きしない
  def test_blank_cell_does_not_overwrite_existing_value
    template_without_start_date = clear_cell(@template_bytes, "G9")
    task = create_task(wbs_level: "1.1", progress_rate: 0.5, workload: 2,
                        start_date: Date.new(2026, 9, 20), end_date: Date.new(2026, 9, 10))

    result = NotionWbsExcelImporter.new(workbook_bytes: template_without_start_date, tasks: [ task ]).call
    task.reload

    assert_nil task.start_date_prev
    assert_equal 0, result[:applied_cell_count]
    assert_equal 0, result[:cleared_cell_count]
    assert_equal 1, result[:unchanged_row_count]
  end

  # シートの値(2026-09-01)がタスクの元の値(2026-09-01)と同じ場合、既存の start_date_prev(修正後)は
  # クリアされる(アップロードされたExcelを正とするため、古い修正後を残さない)
  def test_same_value_as_original_clears_existing_prev_override
    task = create_task(wbs_level: "1.1", progress_rate: 0.5, workload: 2,
                        start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 10),
                        start_date_prev: Date.new(2026, 9, 20))

    result = call_importer([ task ])
    task.reload

    assert_nil task.start_date_prev
    assert_equal 0, result[:applied_cell_count]
    assert_equal 1, result[:cleared_cell_count]
    assert_equal 1, result[:applied_task_count]
    assert_equal 0, result[:unchanged_row_count]
  end

  private

  def create_task(wbs_level:, progress_rate: nil, workload: nil, start_date: nil, end_date: nil,
                   progress_rate_prev: nil, workload_prev: nil, start_date_prev: nil, end_date_prev: nil)
    task = NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: wbs_level, title: "タイトル", assignee_name: "担当",
      progress_rate: progress_rate, workload: workload, start_date: start_date, end_date: end_date,
      progress_rate_prev: progress_rate_prev, workload_prev: workload_prev,
      start_date_prev: start_date_prev, end_date_prev: end_date_prev,
      synced_at: Time.current
    )
    @notion_tasks << task
    task
  end

  def call_importer(tasks)
    NotionWbsExcelImporter.new(workbook_bytes: @template_bytes, tasks: tasks).call
  end

  def read_zip_entries(bytes)
    entries = {}
    Zip::File.open_buffer(StringIO.new(bytes)) { |zip_file| zip_file.each { |entry| entries[entry.name] = entry.get_input_stream.read } }
    entries
  end

  def write_zip_entries(entries)
    buffer = Zip::OutputStream.write_buffer do |zip_output|
      entries.each do |name, content|
        zip_output.put_next_entry(name)
        zip_output.write(content)
      end
    end
    buffer.string
  end

  # 検証用に、シート内の指定セルを丸ごと取り除いた xlsm を作る(空セル扱いのテスト用)
  def clear_cell(bytes, cell_reference)
    entries = read_zip_entries(bytes)
    entries["xl/worksheets/sheet2.xml"] = entries.fetch("xl/worksheets/sheet2.xml")
      .sub(%r{<c r="#{cell_reference}"[^>]*/>|<c r="#{cell_reference}"[^>]*>.*?</c>}, "")
    write_zip_entries(entries)
  end
end
