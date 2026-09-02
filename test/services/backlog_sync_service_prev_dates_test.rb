require "test_helper"

# Backlog 側で開始日/期限日が動いたら、動く前の値を *_prev に残す。
# 進捗カンバンの「修正前 → 修正後」表示はこの値だけを根拠にしている。
class BacklogSyncServicePrevDatesTest < Minitest::Test
  # BacklogClient の差し替え用。同期が呼ぶメソッドだけ持つ。
  class FakeBacklogClient
    def initialize(issues) = @issues = issues
    def fetch_issues(**) = @issues
    def fetch_issues_for(*, **) = @issues
    def find_user_id_by_name(_name) = 1
  end

  def setup
    @user = User.create!(email: "backlog_sync_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "同期所有者")
    @user.create_backlog_setting!(backlog_url: "https://example.backlog.jp", api_key: "dummy-key")
    @original_new = BacklogClient.method(:new)
  end

  def teardown
    BacklogClient.singleton_class.send(:define_method, :new, @original_new) if @original_new
    @user&.destroy
  end

  def sync_with(start_date:, due_date:)
    issues = [ {
      "issueKey" => "TEST-1", "summary" => "テスト課題",
      "status" => { "id" => 2, "name" => "処理中" },
      "created" => "2026-08-01", "startDate" => start_date, "dueDate" => due_date
    } ]
    fake = FakeBacklogClient.new(issues)
    BacklogClient.singleton_class.send(:define_method, :new) { |_setting| fake }
    BacklogSyncService.new(@user).call
    @user.backlog_tasks.find_by!(issue_key: "TEST-1")
  end

  # 初回同期では「変更前」が無いので *_prev は空のまま
  def test_first_sync_leaves_prev_empty
    task = sync_with(start_date: "2026-09-01", due_date: "2026-09-09")

    assert_equal Date.new(2026, 9, 1), task.start_date
    assert_equal Date.new(2026, 9, 9), task.end_date
    assert_nil task.start_date_prev
    assert_nil task.end_date_prev
  end

  # 日付が動いたら、動く前の値が *_prev に残る(現在値は新しい方)
  def test_changed_dates_are_recorded_as_previous_values
    sync_with(start_date: "2026-09-01", due_date: "2026-09-09")
    task = sync_with(start_date: "2026-09-03", due_date: "2026-09-15")

    assert_equal Date.new(2026, 9, 3), task.start_date
    assert_equal Date.new(2026, 9, 1), task.start_date_prev
    assert_equal Date.new(2026, 9, 15), task.end_date
    assert_equal Date.new(2026, 9, 9), task.end_date_prev
  end

  # 変わっていない項目の *_prev は上書きしない(直前の変更を握りつぶさない)
  def test_unchanged_date_keeps_its_previous_value
    sync_with(start_date: "2026-09-01", due_date: "2026-09-09")
    sync_with(start_date: "2026-09-03", due_date: "2026-09-09")
    task = sync_with(start_date: "2026-09-03", due_date: "2026-09-20")

    assert_equal Date.new(2026, 9, 1), task.start_date_prev, "開始日は動いていないので前回の変更前を保つ"
    assert_equal Date.new(2026, 9, 9), task.end_date_prev
  end

  # 日付が消された(nil になった)ときも変更として記録する
  def test_cleared_date_is_recorded_as_a_change
    sync_with(start_date: "2026-09-01", due_date: "2026-09-09")
    task = sync_with(start_date: nil, due_date: "2026-09-09")

    assert_nil task.start_date
    assert_equal Date.new(2026, 9, 1), task.start_date_prev
  end
end
