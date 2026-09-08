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

  # 1.1 に一致する既存行(9行目)。C〜H すべてに *_prev(修正後)があれば、その値だけを反映する
  def test_matches_existing_row_and_writes_all_overridden_columns
    task = create_task(wbs_level: "1.1", title: "元タイトルA", title_prev: "更新後タスクA",
                        assignee_name: "担当A", assignee_name_prev: "担当A2",
                        workload: 1, workload_prev: 2.5, progress_rate: 0, progress_rate_prev: 0.8,
                        start_date: Date.new(2026, 9, 1), start_date_prev: Date.new(2026, 9, 2),
                        end_date: Date.new(2026, 9, 10), end_date_prev: Date.new(2026, 9, 12))

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
    assert_equal 6, result[:changed_cell_count]
    assert_equal 6, result[:unsubmitted_cell_count]
  end

  # 2.1.1 に一致する既存行(12行目)。title_prev/assignee_name_prev(修正後)だけがある場合、
  # その2列だけを書き換え、他の列(E〜H)のセルは元のまま一切触らない
  def test_matches_existing_row_and_leaves_non_overridden_columns_untouched
    task = create_task(wbs_level: "2.1.1", title: "元タイトルC", title_prev: "修正後タイトルC",
                        assignee_name: "担当A", assignee_name_prev: "担当A2",
                        workload: 1, progress_rate: 0,
                        start_date: Date.new(2026, 9, 15), end_date: Date.new(2026, 9, 20))

    result = call_updater([ task ])
    row_12 = row_values(result[:bytes], 12)

    assert_equal "　修正後タイトルC", row_12["C"]
    assert_equal "担当A2", row_12["D"]
    assert_equal "0", row_12["E"]     # 元の値のまま(progress_rate_prev 無し)
    assert_equal "1", row_12["F"]     # 元の値のまま(workload_prev 無し)
    assert_equal "46280", row_12["G"] # 元の値のまま(start_date_prev 無し)
    assert_equal "46285", row_12["H"] # 元の値のまま(end_date_prev 無し)
    assert_equal 1, result[:matched_count]
    assert_equal 2, result[:changed_cell_count]
    assert_equal 2, result[:unsubmitted_cell_count]
  end

  # override が一つも無い既存行は C〜H を一切書かない(セル単位ではなく行全体が元のバイト列と一致する)
  def test_matched_row_without_any_override_is_byte_identical_to_the_original
    task = create_task(wbs_level: "1.1", title: "書き込まれないタイトル", assignee_name: "書き込まれない担当",
                        workload: 1, progress_rate: 0,
                        start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 2))

    result = call_updater([ task ])

    assert_equal raw_row_xml(@template_bytes, 9), raw_row_xml(result[:bytes], 9)
    assert_equal 1, result[:matched_count]
    assert_equal 0, result[:changed_cell_count]
    assert_equal 0, result[:unsubmitted_cell_count]
  end

  # start_date_prev だけがある既存行は G だけを書き、背景を赤く塗る(未提出の変更)。
  # styles.xml の fills には赤(FFFF9999)が1回だけ追加される
  def test_matched_row_with_unsubmitted_override_paints_only_that_cell_red
    task = create_task(wbs_level: "1.1", title: "任意タイトル", assignee_name: "任意担当",
                        workload: 1, progress_rate: 0,
                        start_date: Date.new(2026, 9, 1), start_date_prev: Date.new(2026, 9, 20),
                        end_date: nil)

    result = call_updater([ task ])
    row_9 = row_values(result[:bytes], 9)
    expected_serial = (Date.new(2026, 9, 20) - EXCEL_EPOCH).to_i.to_s

    assert_equal "　ダミータスクA", row_9["C"] # 元のまま
    assert_equal "担当A", row_9["D"]           # 元のまま
    assert_equal "0.5", row_9["E"]             # 元のまま
    assert_equal "2", row_9["F"]               # 元のまま
    assert_equal expected_serial, row_9["G"]
    assert_equal "46275", row_9["H"]           # 元のまま
    assert_equal 1, result[:changed_cell_count]
    assert_equal 1, result[:unsubmitted_cell_count]

    refute_equal cell_style_id(@template_bytes, "G9"), cell_style_id(result[:bytes], "G9")
    assert_equal cell_style_id(@template_bytes, "D9"), cell_style_id(result[:bytes], "D9") # 触っていない列のスタイルは変わらない
    assert_includes styles_fills_xml(result[:bytes]), "FFFF9999"
  end

  # 提出済(mark_overrides_submitted!)にした後は同じ値を書いても背景を赤くしない(s は元のまま)
  def test_matched_row_after_marking_submitted_writes_value_without_red_style
    task = create_task(wbs_level: "1.1", title: "任意タイトル", assignee_name: "任意担当",
                        workload: 1, progress_rate: 0,
                        start_date: Date.new(2026, 9, 1), start_date_prev: Date.new(2026, 9, 20),
                        end_date: nil)
    task.mark_overrides_submitted!

    result = call_updater([ task ])
    row_9 = row_values(result[:bytes], 9)
    expected_serial = (Date.new(2026, 9, 20) - EXCEL_EPOCH).to_i.to_s

    assert_equal expected_serial, row_9["G"] # 値は提出済でも書かれる
    assert_equal 1, result[:changed_cell_count]
    assert_equal 0, result[:unsubmitted_cell_count]
    assert_equal cell_style_id(@template_bytes, "G9"), cell_style_id(result[:bytes], "G9")
  end

  # 修正後の値が登録済みテンプレ(元のG9=2026-09-01)と同じ場合は、未提出でも背景を赤くしない
  # (テンプレと同じ値を出力しても見た目が変わらないため)
  def test_matched_row_with_override_equal_to_template_value_is_not_painted_red
    task = create_task(wbs_level: "1.1", title: "任意タイトル", assignee_name: "任意担当",
                        workload: 1, progress_rate: 0,
                        start_date: Date.new(2026, 8, 1), start_date_prev: Date.new(2026, 9, 1),
                        end_date: nil)

    result = call_updater([ task ])
    row_9 = row_values(result[:bytes], 9)
    expected_serial = (Date.new(2026, 9, 1) - EXCEL_EPOCH).to_i.to_s

    assert_equal expected_serial, row_9["G"]
    assert_equal 1, result[:changed_cell_count]
    assert_equal 0, result[:unsubmitted_cell_count]
    assert_equal cell_style_id(@template_bytes, "G9"), cell_style_id(result[:bytes], "G9")
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
    task = create_task(wbs_level: "1.1", title: "元タイトル", title_prev: "セル欠損対応タスク",
                        assignee_name: "担当X",
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
                   title_prev: nil, assignee_name_prev: nil, workload_prev: nil, progress_rate_prev: nil,
                   start_date_prev: nil, end_date_prev: nil)
    task = NotionTask.create!(
      notion_block_id: SecureRandom.uuid,
      wbs_level: wbs_level, title: title, title_prev: title_prev,
      assignee_name: assignee_name, assignee_name_prev: assignee_name_prev,
      workload: workload, workload_prev: workload_prev,
      progress_rate: progress_rate, progress_rate_prev: progress_rate_prev,
      start_date: start_date, start_date_prev: start_date_prev,
      end_date: end_date, end_date_prev: end_date_prev,
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

  # 検証用に、行全体の生 XML を取り出す(セル単位ではなく行が一切変わっていないことを確認する用)
  def raw_row_xml(bytes, row_number)
    entries = read_zip_entries(bytes)
    entries.fetch("xl/worksheets/sheet2.xml")[/<row r="#{row_number}"[^>]*>.*?<\/row>/m]
  end

  # 検証用に、指定セルのスタイル(s属性)を取り出す
  def cell_style_id(bytes, cell_reference)
    entries = read_zip_entries(bytes)
    sheet_document = Nokogiri::XML(entries.fetch("xl/worksheets/sheet2.xml"))
    sheet_document.at_xpath("//xmlns:c[@r='#{cell_reference}']", "xmlns" => MAIN_NS)&.attribute("s")&.value
  end

  # 検証用に、xl/styles.xml の <fills> 部分の生 XML を取り出す
  def styles_fills_xml(bytes)
    entries = read_zip_entries(bytes)
    entries.fetch("xl/styles.xml")[/<fills[^>]*>.*?<\/fills>/m]
  end
end
