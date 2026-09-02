require "test_helper"

# NotionLineReport: リビング(Notion)タスクの LINE 報告文面。
# 変更があった項目は「修正前 → 修正後」、無ければ現在値だけを出す。
class NotionLineReportTest < ActiveSupport::TestCase
  def build_task(attrs = {})
    NotionTask.create!({
      notion_block_id: SecureRandom.uuid,
      title: "見積書",
      wbs_level: "2.2.7.3.5",
      start_date: Date.new(2026, 9, 15),
      end_date: Date.new(2026, 9, 22),
      progress_rate: 0.9,
      synced_at: Time.current
    }.merge(attrs))
  end

  def teardown
    NotionTask.where("title LIKE ?", "見積書%").delete_all
  end

  def test_changed_fields_show_before_and_after
    task = build_task(start_date_prev: Date.new(2026, 9, 10), progress_rate_prev: 0.7)

    message = NotionLineReport.new([ task ], reporter: "川村卓也").message

    assert_includes message, "📋 進捗報告（川村卓也）"
    assert_includes message, "タスク: 見積書 2.2.7.3.5"
    assert_includes message, "開始日: 2026/09/10 → 9/15"
    assert_includes message, "終了日: 2026/09/22"
    assert_includes message, "進捗率: 70% → 90%"
    assert_includes message, "リンク\nhttps://www.notion.so/"
    assert_includes message, task.notion_block_id.delete("-")
  end

  def test_unchanged_fields_show_single_values
    task = build_task

    message = NotionLineReport.new([ task ]).message

    assert_includes message, "開始日: 2026/09/15"
    assert_includes message, "終了日: 2026/09/22"
    assert_includes message, "進捗率: 90%"
    refute_includes message, "→"
  end

  def test_status_and_note_lines_appear_only_when_present
    task = build_task(status: "完了", status_prev: "進行中", note: "先行手配済み")

    message = NotionLineReport.new([ task ]).message

    assert_includes message, "ステータス: 進行中 → 完了"
    assert_includes message, "備考(遅れた理由など): 先行手配済み"
    refute_includes NotionLineReport.new([ build_task(notion_block_id: SecureRandom.uuid) ]).message, "ステータス:"
  end

  def test_multiple_tasks_are_separated_by_blank_lines
    first_task = build_task(title: "見積書A")
    second_task = build_task(title: "見積書B", notion_block_id: SecureRandom.uuid)

    message = NotionLineReport.new([ first_task, second_task ]).message

    assert_includes message, "タスク: 見積書A"
    assert_includes message, "タスク: 見積書B"
    assert_equal 2, message.scan(/^タスク: /).size
  end
end
