require "test_helper"

# LineReportArchiver: 送信文面の upsert(同じ日付×同じタスクは上書き)とシート同期の呼び出し。
class LineReportArchiverTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "archiver_#{SecureRandom.hex(4)}@example.com", password: "password123",
                         display_name: "報告 太郎", closing_day: 25)
    @synced_calls = []
    @original_sync = LineReportSheetSync.method(:sync)
    calls = @synced_calls
    LineReportSheetSync.define_singleton_method(:sync) do |operator:, month:|
      calls << { operator: operator, month: month }
      { sheet: "stub", rows: calls.size }
    end
  end

  def teardown
    LineReportSheetSync.define_singleton_method(:sync, @original_sync)
    LineReportEntry.where(user_id: @user.id).delete_all
    @user.destroy
  end

  def test_records_entries_and_syncs_the_month
    message = "タスク: A\n進捗率: 50%\n\nタスク: B\n進捗率: 80%"

    result = LineReportArchiver.record(user: @user, message: message, reported_on: Date.new(2026, 9, 2))

    assert_equal({ archived: 2, sheet_synced: true }, result)
    assert_equal 2, LineReportEntry.where(user_id: @user.id, reported_on: Date.new(2026, 9, 2)).count
    assert_equal [ { operator: @user, month: Date.new(2026, 9, 2) } ], @synced_calls
  end

  def test_same_date_and_task_is_updated_not_duplicated
    reported_on = Date.new(2026, 9, 2)
    LineReportArchiver.record(user: @user, message: "タスク: A\n進捗率: 50%", reported_on: reported_on)
    LineReportArchiver.record(user: @user, message: "タスク: A\n進捗率: 80%\n備考: 追記", reported_on: reported_on)

    entries = LineReportEntry.where(user_id: @user.id, reported_on: reported_on)
    assert_equal 1, entries.count
    assert_equal "80%", entries.first.progress_text
    assert_equal "追記", entries.first.note
  end

  def test_sheet_failure_does_not_raise_and_is_reported
    LineReportSheetSync.define_singleton_method(:sync) { |operator:, month:| raise "boom" }

    result = LineReportArchiver.record(user: @user, message: "タスク: A", reported_on: Date.new(2026, 9, 2))

    assert_equal 1, result[:archived]
    assert_equal false, result[:sheet_synced]
    assert_equal "boom", result[:sheet_error]
    assert_equal 1, LineReportEntry.where(user_id: @user.id).count
  end

  def test_free_text_message_records_nothing
    result = LineReportArchiver.record(user: @user, message: "進捗ありません")

    assert_equal({ archived: 0, sheet_synced: false }, result)
    assert_equal 0, LineReportEntry.where(user_id: @user.id).count
    assert_empty @synced_calls
  end
end
