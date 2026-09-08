require "test_helper"
require "zip"
require "stringio"

# NotionWbsExcelUpdater: 受領Excel(xlsm)「プロジェクトのスケジュール」シートに
# Notion(WBS) タスクの実効値(*_prev があればそれ、無ければ元の値)を書き込む。
# openpyxl での再保存だと消える VBA・条件付き書式(x14拡張)・calcChain の扱いを検証する。
class NotionWbsExcelUpdaterTest < Minitest::Test
  TEMPLATE_PATH = Rails.root.join("test/fixtures/files/wbs_schedule_template.xlsm")
  EXCEL_EPOCH = Date.new(1899, 12, 30)
  MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main".freeze

  def setup
    @template_bytes = File.binread(TEMPLATE_PATH)
    @notion_tasks = []
  end

  def teardown
    @notion_tasks.each(&:destroy)
  end

  # 1.1 に一致する既存行(9行目)を実効値で上書きする(インデント保持)
  def test_matches_existing_row_by_wbs_level_and_overwrites_effective_values
    task = create_task(wbs_level: "1.1", title: "更新後タスクA", assignee_name: "担当A2",
                        workload: 2.5, progress_rate: 0.8,
                        start_date: Date.new(2026, 9, 2), end_date: Date.new(2026, 9, 12))

    result = call_updater([ task ])
    row_9 = row_values(result[:bytes], 9)

    assert_equal "1.1", row_9["B_raw"] # B(突合キー)は既存行では変更しない
    assert_equal "　更新後タスクA", row_9["C"]
    assert_equal "担当A2", row_9["D"]
    assert_equal "0.8", row_9["E"]
    assert_equal "2.5", row_9["F"]
    assert_equal "46267", row_9["G"]
    assert_equal "46277", row_9["H"]
    assert_equal 1, result[:matched_count]
    assert_equal 0, result[:appended_count]
  end

  # 2.1.1 に一致する既存行(12行目)。title_prev/assignee_name_prev(修正後)がある場合はそちらを優先する
  def test_uses_prev_columns_as_effective_values_when_present
    task = create_task(wbs_level: "2.1.1", title: "元タイトルC", title_prev: "修正後タイトルC",
                        assignee_name: "担当A", assignee_name_prev: "担当A2",
                        workload: 1, progress_rate: 0,
                        start_date: Date.new(2026, 9, 15), end_date: Date.new(2026, 9, 20))

    result = call_updater([ task ])
    row_12 = row_values(result[:bytes], 12)

    assert_equal "　修正後タイトルC", row_12["C"]
    assert_equal "担当A2", row_12["D"]
    assert_equal "0", row_12["E"]
    assert_equal 1, result[:matched_count]
  end

  # 3.1 は既存行に無いので、最後のデータ行(12行目)の次の空行(13行目)に追加する
  def test_appends_unmatched_task_to_the_next_empty_row
    task = create_task(wbs_level: "3.1", title: "新規タスクD", assignee_name: "担当D",
                        workload: 4, progress_rate: 0.2,
                        start_date: Date.new(2026, 9, 21), end_date: Date.new(2026, 9, 25))

    result = call_updater([ task ])
    row_13 = row_values(result[:bytes], 13)

    assert_equal "3.1", row_13["B"]
    assert_equal "　新規タスクD", row_13["C"]
    assert_equal "担当D", row_13["D"]
    assert_equal "0.2", row_13["E"]
    assert_equal "4", row_13["F"]
    assert_equal "46286", row_13["G"]
    assert_equal "46290", row_13["H"]
    assert_equal 0, result[:matched_count]
    assert_equal 1, result[:appended_count]
    assert_equal 0, result[:skipped_count]
  end

  # 4件まとめて処理: 1.1一致・2.1.1一致(修正後あり)・3.1新規・1.2一致 を一度に検証する
  def test_processes_multiple_tasks_together
    tasks = [
      create_task(wbs_level: "1.1", title: "更新後タスクA", assignee_name: "担当A2",
                  workload: 2.5, progress_rate: 0.8,
                  start_date: Date.new(2026, 9, 2), end_date: Date.new(2026, 9, 12)),
      create_task(wbs_level: "1.2", title: "ダミータスクB", assignee_name: "担当B",
                  workload: 3, progress_rate: 1,
                  start_date: Date.new(2026, 9, 5), end_date: Date.new(2026, 9, 7)),
      create_task(wbs_level: "2.1.1", title: "元タイトルC", title_prev: "修正後タイトルC",
                  assignee_name: "担当A", assignee_name_prev: "担当A2",
                  workload: 1, progress_rate: 0,
                  start_date: Date.new(2026, 9, 15), end_date: Date.new(2026, 9, 20)),
      create_task(wbs_level: "3.1", title: "新規タスクD", assignee_name: "担当D",
                  workload: 4, progress_rate: 0.2,
                  start_date: Date.new(2026, 9, 21), end_date: Date.new(2026, 9, 25))
    ]

    result = call_updater(tasks)

    assert_equal 3, result[:matched_count]
    assert_equal 1, result[:appended_count]
    assert_equal 0, result[:skipped_count]
  end

  # 183行を超える追記分は書かずに skipped_count に数える
  def test_skips_tasks_beyond_the_last_data_row
    # 直接 13 行目以降を全部埋める代わりに、追記上限(183行目)を超えるタスクを大量投入して検証する
    tasks = (0..200).map do |offset|
      create_task(wbs_level: "9.#{offset}", title: "大量投入タスク#{offset}", assignee_name: "担当X",
                  workload: 1, progress_rate: 0,
                  start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 2))
    end

    result = call_updater(tasks)

    assert_equal 0, result[:matched_count]
    assert_equal 171, result[:appended_count]  # 13行目〜183行目 = 171行
    assert_equal 30, result[:skipped_count]
  end

  # 既存行に C セルが無くても、追加行と同じ「列順に生成＋直前データ行のスタイル継承」で補って書き込む
  def test_fills_missing_cell_on_matched_row
    template_without_c9 = remove_cell_from_sheet(@template_bytes, "C9")
    task = create_task(wbs_level: "1.1", title: "セル欠損対応タスク", assignee_name: "担当X",
                        workload: 1, progress_rate: 0.5,
                        start_date: Date.new(2026, 9, 2), end_date: Date.new(2026, 9, 12))

    result = NotionWbsExcelUpdater.new(template_bytes: template_without_c9, tasks: [ task ]).call
    row_9 = row_values(result[:bytes], 9)

    assert_equal "　セル欠損対応タスク", row_9["C"]
    assert_equal 1, result[:matched_count]
  end

  # WBSレベル未設定のタスクは行を追加せず skipped_count に数える(空キーの行が増えるのを防ぐ)
  def test_skips_task_with_blank_wbs_level_without_consuming_an_append_row
    blank_wbs_task = create_task(wbs_level: "", title: "WBS未設定タスク", assignee_name: "担当Y",
                                  workload: 1, progress_rate: 0,
                                  start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 2))
    new_task = create_task(wbs_level: "3.1", title: "新規タスクD", assignee_name: "担当D",
                            workload: 4, progress_rate: 0.2,
                            start_date: Date.new(2026, 9, 21), end_date: Date.new(2026, 9, 25))

    result = call_updater([ blank_wbs_task, new_task ])

    assert_equal 0, result[:matched_count]
    assert_equal 1, result[:appended_count]
    assert_equal 1, result[:skipped_count]
    row_13 = row_values(result[:bytes], 13)
    assert_equal "3.1", row_13["B"] # 空WBSレベルのタスクは行を消費しない(13行目は3.1のまま)
  end

  # VBA・条件付き書式(x14拡張)・calcChain の扱い
  def test_preserves_vba_and_conditional_formatting_and_removes_calc_chain
    task = create_task(wbs_level: "1.1", title: "更新後タスクA", assignee_name: "担当A2",
                        workload: 2.5, progress_rate: 0.8,
                        start_date: Date.new(2026, 9, 2), end_date: Date.new(2026, 9, 12))

    result = call_updater([ task ])
    original_entries = read_zip_entries(@template_bytes)
    updated_entries = read_zip_entries(result[:bytes])

    assert_equal original_entries["xl/vbaProject.bin"], updated_entries["xl/vbaProject.bin"]

    original_sheet = original_entries.fetch("xl/worksheets/sheet2.xml")
    updated_sheet = updated_entries.fetch("xl/worksheets/sheet2.xml")
    assert_equal original_sheet.scan("<conditionalFormatting").size, updated_sheet.scan("<conditionalFormatting").size
    assert_includes updated_sheet, "<extLst>"

    refute updated_entries.key?("xl/calcChain.xml")
    workbook_xml = updated_entries.fetch("xl/workbook.xml")
    assert_match(/<calcPr[^>]*fullCalcOnLoad="1"/, workbook_xml)
  end

  private

  def create_task(wbs_level:, title:, assignee_name:, workload:, progress_rate:, start_date:, end_date:,
                   title_prev: nil, assignee_name_prev: nil)
    task = NotionTask.create!(
      notion_block_id: SecureRandom.uuid,
      wbs_level: wbs_level, title: title, title_prev: title_prev,
      assignee_name: assignee_name, assignee_name_prev: assignee_name_prev,
      workload: workload, progress_rate: progress_rate,
      start_date: start_date, end_date: end_date,
      synced_at: Time.current
    )
    @notion_tasks << task
    task
  end

  def call_updater(tasks)
    NotionWbsExcelUpdater.new(template_bytes: @template_bytes, tasks: tasks).call
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

  # 検証用に、シート内の指定セルを丸ごと取り除いた xlsm を作る(欠損セル補完のテスト用)
  def remove_cell_from_sheet(bytes, cell_reference)
    entries = read_zip_entries(bytes)
    entries["xl/worksheets/sheet2.xml"] = entries.fetch("xl/worksheets/sheet2.xml")
      .sub(%r{<c r="#{cell_reference}"[^>]*/>|<c r="#{cell_reference}"[^>]*>.*?</c>}, "")
    write_zip_entries(entries)
  end

  # 検証用に行の値を独自に読み取る(サービス実装をそのまま再利用しない)
  def row_values(bytes, row_number)
    entries = read_zip_entries(bytes)
    sheet_document = Nokogiri::XML(entries.fetch("xl/worksheets/sheet2.xml"))
    row_node = sheet_document.at_xpath("//xmlns:sheetData/xmlns:row[@r='#{row_number}']", "xmlns" => MAIN_NS)
    values = {}
    %w[B C D E F G H].each do |column_letter|
      cell_node = row_node.xpath("xmlns:c", "xmlns" => MAIN_NS)
        .find { |cell| cell["r"][/\A[A-Z]+/] == column_letter }
      next if cell_node.nil?

      values[column_letter] = cell_node.at_xpath("xmlns:is/xmlns:t", "xmlns" => MAIN_NS)&.text ||
        cell_node.at_xpath("xmlns:v", "xmlns" => MAIN_NS)&.text
    end
    values["B_raw"] = values["B"]
    values
  end
end
