require "test_helper"
require "ostruct"

# NotionTaskImporter: Notion(WBS) タブのスプレッドシートを読み、notion_tasks の「修正後」値を取り込む（スプシ→アプリ）。
# Google API は呼ばず、authorized_sheets_service を偽 service に差し替えてタブ解決・range・値反映を検証する。
class NotionTaskImporterTest < Minitest::Test
  HEADER_ROW = [
    "担当", "WBSレベル", "タスク名",
    "開始日(修正前)", "開始日(修正後)",
    "終了日(修正前)", "終了日(修正後)",
    "工数",
    "進捗率(修正前)", "進捗率(修正後)",
    "進捗状況(修正前)", "進捗状況(修正後)",
    "優先度", "備考", "メモ"
  ].freeze

  def setup
    @operator = User.create!(
      email: "notion_importer_operator_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "Notion取込担当"
    )
    @notion_tasks = []
  end

  def teardown
    @notion_tasks.each(&:destroy)
    @operator&.destroy
  end

  # 1. gid 付き URL では gid が一致するタブ名が range に使われる
  def test_uses_tab_matched_by_gid_in_url
    sheets = [
      sheet_properties(sheet_id: 111, title: "その他タブ"),
      sheet_properties(sheet_id: 1287451848, title: "主タブ")
    ]
    recorded_ranges = []
    service = fake_service(sheets: sheets, values: [ HEADER_ROW ], recorded_ranges: recorded_ranges)
    importer = build_importer(
      url: "https://docs.google.com/spreadsheets/d/abc123/edit#gid=1287451848",
      service: service
    )

    result = importer.call

    assert_equal [ "主タブ!A1:O1000" ], recorded_ranges
    assert_equal "主タブ", result[:tab]
    assert_equal 0, result[:imported_rows]
    assert_equal 0, result[:skipped_rows]
  end

  # 2. gid 無し URL は "Notion(WBS)" タブにフォールバックする
  def test_falls_back_to_notion_wbs_tab_when_no_gid
    sheets = [
      sheet_properties(sheet_id: 222, title: "Notion(WBS)"),
      sheet_properties(sheet_id: 333, title: "別タブ")
    ]
    recorded_ranges = []
    service = fake_service(sheets: sheets, values: [ HEADER_ROW ], recorded_ranges: recorded_ranges)
    importer = build_importer(
      url: "https://docs.google.com/spreadsheets/d/abc123/edit",
      service: service
    )

    result = importer.call

    assert_equal [ "Notion(WBS)!A1:O1000" ], recorded_ranges
    assert_equal "Notion(WBS)", result[:tab]
  end

  # 3. gid が無く "Notion(WBS)" タブも無いと raise する
  def test_raises_when_no_gid_and_no_notion_wbs_tab
    sheets = [ sheet_properties(sheet_id: 444, title: "無関係タブ") ]
    service = fake_service(sheets: sheets, values: [ HEADER_ROW ])
    importer = build_importer(
      url: "https://docs.google.com/spreadsheets/d/abc123/edit",
      service: service
    )

    error = assert_raises(RuntimeError) { importer.call }
    assert_includes error.message, "Notion(WBS)"
  end

  # 4. 修正後の値（開始日/終了日/進捗率/進捗状況/備考/メモ）が *_prev / note / memo に反映される
  def test_imports_prev_values_from_after_correction_columns
    task = create_notion_task(wbs_level: "1.1", title: "設計タスク")

    row = Array.new(15)
    row[0]  = "山田"
    row[1]  = "1.1"
    row[2]  = "設計タスク"
    row[3]  = 46200               # 開始日(修正前)
    row[4]  = 46272               # 開始日(修正後) = 2026-09-07
    row[5]  = "2026-09-10"        # 終了日(修正前)
    row[6]  = "2026-09-22"        # 終了日(修正後)
    row[7]  = 5.5                 # 工数
    row[8]  = "60%"               # 進捗率(修正前)
    row[9]  = "90%"               # 進捗率(修正後)
    row[10] = "進行中"            # 進捗状況(修正前)
    row[11] = "未着手"            # 進捗状況(修正後)
    row[12] = "高"                # 優先度
    row[13] = "備考文"            # 備考
    row[14] = "メモ文"            # メモ

    sheets = [ sheet_properties(sheet_id: 222, title: "Notion(WBS)") ]
    service = fake_service(sheets: sheets, values: [ HEADER_ROW, row ])
    importer = build_importer(
      url: "https://docs.google.com/spreadsheets/d/abc123/edit",
      service: service
    )

    result = importer.call
    task.reload

    assert_equal 1, result[:imported_rows]
    assert_equal 0, result[:skipped_rows]
    assert_equal Date.new(2026, 9, 7), task.start_date_prev
    assert_equal Date.new(2026, 9, 22), task.end_date_prev
    assert_in_delta 0.9, task.progress_rate_prev, 0.001
    assert_equal "未着手", task.status_prev
    assert_equal "備考文", task.note
    assert_equal "メモ文", task.memo
  end

  # 5. 空セルはアプリ値を消さない。ただしメモだけは空文字で上書きされる
  def test_blank_cells_do_not_clear_existing_values_except_memo
    task = create_notion_task(
      wbs_level: "2.2",
      title: "既存タスク",
      start_date_prev: Date.new(2026, 1, 1),
      memo: "旧"
    )

    row = Array.new(15)
    row[0] = "佐藤"
    row[1] = "2.2"
    row[2] = "既存タスク"
    # row[4] (開始日(修正後)) は空のまま
    row[14] = "" # メモは空文字を明示

    sheets = [ sheet_properties(sheet_id: 222, title: "Notion(WBS)") ]
    service = fake_service(sheets: sheets, values: [ HEADER_ROW, row ])
    importer = build_importer(
      url: "https://docs.google.com/spreadsheets/d/abc123/edit",
      service: service
    )

    importer.call
    task.reload

    assert_equal Date.new(2026, 1, 1), task.start_date_prev
    assert_equal "", task.memo
  end

  # 6. アプリに無い WBS レベルの行は skipped_rows に加算され、新規作成もされない
  def test_unmatched_wbs_level_row_is_skipped
    row = Array.new(15)
    row[0] = "鈴木"
    row[1] = "99.99"
    row[2] = "存在しないタスク"

    sheets = [ sheet_properties(sheet_id: 222, title: "Notion(WBS)") ]
    service = fake_service(sheets: sheets, values: [ HEADER_ROW, row ])
    importer = build_importer(
      url: "https://docs.google.com/spreadsheets/d/abc123/edit",
      service: service
    )

    count_before = NotionTask.count
    result = importer.call

    assert_equal 0, result[:imported_rows]
    assert_equal 1, result[:skipped_rows]
    assert_equal count_before, NotionTask.count
    assert_nil NotionTask.find_by(wbs_level: "99.99")
  end

  private

  def create_notion_task(wbs_level:, title:, **attrs)
    task = NotionTask.create!(
      notion_block_id: SecureRandom.uuid,
      wbs_level: wbs_level,
      title: title,
      synced_at: Time.current,
      **attrs
    )
    @notion_tasks << task
    task
  end

  def sheet_properties(sheet_id:, title:)
    OpenStruct.new(properties: OpenStruct.new(sheet_id: sheet_id, title: title))
  end

  # get_spreadsheet / get_spreadsheet_values の最小限のスタブ。呼ばれた range は recorded_ranges に記録する。
  def fake_service(sheets:, values:, recorded_ranges: [])
    service = Object.new
    service.define_singleton_method(:get_spreadsheet) do |_id, fields:|
      OpenStruct.new(sheets: sheets)
    end
    service.define_singleton_method(:get_spreadsheet_values) do |_id, range, value_render_option:|
      recorded_ranges << range
      OpenStruct.new(values: values)
    end
    service
  end

  def build_importer(url:, service:)
    importer = NotionTaskImporter.new(operator: @operator, spreadsheet_url: url)
    importer.define_singleton_method(:authorized_sheets_service) { |*_args| service }
    importer
  end
end
