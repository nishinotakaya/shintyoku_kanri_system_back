require "test_helper"

# LineReportMessageParser: LINE 送信文面 → タスク単位の構造化データ。
class LineReportMessageParserTest < ActiveSupport::TestCase
  def test_parses_multiple_tasks_with_all_fields
    message = <<~TEXT
      📋 進捗報告（西野）

      タスク: 見積書 2.2.7.3.5
      開始日: 2026/09/10 → 9/15
      終了日: 2026/09/22
      進捗率: 70% → 90%
      ステータス: 処理中 → 処理済
      備考(遅れた理由など): 仕様追加のため
      リンク
      https://www.notion.so/abc

      タスク: 帳票レイアウト
      開始日: -
      終了日: 2026/09/30
      進捗率: 10%
    TEXT

    entries = LineReportMessageParser.parse(message)

    assert_equal 2, entries.size
    first_entry = entries[0]
    assert_equal "見積書 2.2.7.3.5", first_entry[:task_title]
    assert_equal "2026/09/10 → 9/15", first_entry[:start_date_text]
    assert_equal "2026/09/22", first_entry[:end_date_text]
    assert_equal "70% → 90%", first_entry[:progress_text]
    assert_equal "処理中 → 処理済", first_entry[:status_text]
    assert_equal "仕様追加のため", first_entry[:note]
    assert_equal "https://www.notion.so/abc", first_entry[:url]

    second_entry = entries[1]
    assert_equal "帳票レイアウト", second_entry[:task_title]
    assert_equal "-", second_entry[:start_date_text]
    assert_nil second_entry[:status_text]
    assert_nil second_entry[:url]
  end

  def test_accepts_joutai_label_and_multiline_note
    message = <<~TEXT
      タスク: 移行バッチ
      状態: 進行中
      備考: 障害対応で中断
      再開は明日
      リンク
      https://example.com/t/1
    TEXT

    entries = LineReportMessageParser.parse(message)

    assert_equal 1, entries.size
    assert_equal "進行中", entries[0][:status_text]
    assert_equal "障害対応で中断\n再開は明日", entries[0][:note]
    assert_equal "https://example.com/t/1", entries[0][:url]
  end

  def test_returns_empty_for_free_text_without_task_lines
    assert_equal [], LineReportMessageParser.parse("今日は進捗ありません")
    assert_equal [], LineReportMessageParser.parse("")
    assert_equal [], LineReportMessageParser.parse(nil)
  end
end
