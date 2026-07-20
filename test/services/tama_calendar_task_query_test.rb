require "test_helper"

# TamaCalendarTaskQuery: カレンダー「当日のタスク」タマタブの絞り込み。
# Wing(backlog連携)ワークスペース + 旧データ(workspace未割当) のみを返し、
# テックリーダーズ(trello)/プライベート等のカンバンで作ったタスクを混ぜないことを検証する。
class TamaCalendarTaskQueryTest < Minitest::Test
  TARGET_DATE = Date.new(2026, 7, 20)

  def setup
    @user = User.create!(
      email: "tama_calendar_query_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "タマカレンダー検証"
    )
    ProgressWorkspace.ensure_defaults!(@user)
    @wing_workspace = @user.progress_workspaces.find_by!(builtin: true, source_type: "backlog")
    @tech_leaders_workspace = @user.progress_workspaces.find_by!(builtin: true, source_type: "trello")
    @private_workspace = @user.progress_workspaces.find_by!(builtin: true, name: "プライベート")
  end

  def teardown
    @user&.destroy
  end

  # 1. Wing ワークスペースの backlog タスクは表示される
  def test_wing_backlog_task_is_included
    task = create_task(source: "backlog", progress_workspace_id: @wing_workspace.id)

    assert_includes call_query.map(&:id), task.id
  end

  # 2. ワークスペース未割当(旧データ・カレンダーから日付指定で作った local タスク)は表示される
  def test_task_without_workspace_is_included
    task = create_task(source: "local", progress_workspace_id: nil)

    assert_includes call_query.map(&:id), task.id
  end

  # 3. テックリーダーズのカンバンで手作成した local タスクは表示されない(混入バグの回帰テスト)
  def test_local_task_in_tech_leaders_workspace_is_excluded
    task = create_task(source: "local", progress_workspace_id: @tech_leaders_workspace.id)

    refute_includes call_query.map(&:id), task.id
  end

  # 4. Trello 同期タスク(source=trello)は表示されない
  def test_trello_source_task_is_excluded
    task = create_task(source: "trello", progress_workspace_id: @tech_leaders_workspace.id)

    refute_includes call_query.map(&:id), task.id
  end

  # 5. プライベートのカンバンで手作成した local タスクは表示されない
  def test_local_task_in_private_workspace_is_excluded
    task = create_task(source: "local", progress_workspace_id: @private_workspace.id)

    refute_includes call_query.map(&:id), task.id
  end

  # 6. リビング(source=notion)タスクは表示されない
  def test_notion_source_task_is_excluded
    task = create_task(source: "notion", progress_workspace_id: nil)

    refute_includes call_query.map(&:id), task.id
  end

  # 7. assignee 指定時は担当者名の部分一致で絞り込まれる
  def test_assignee_filter_narrows_by_partial_match
    nishino_task = create_task(source: "backlog", progress_workspace_id: @wing_workspace.id, assignee_name: "西野 鷹也")
    kawamura_task = create_task(source: "backlog", progress_workspace_id: @wing_workspace.id, assignee_name: "川村卓也")

    result_ids = call_query(assignee: "西野").map(&:id)

    assert_includes result_ids, nishino_task.id
    refute_includes result_ids, kawamura_task.id
  end

  # 8. 完了タスクは完了後3日間だけ表示される
  def test_completed_task_visible_only_for_three_days
    recent_completed = create_task(
      source: "backlog", progress_workspace_id: @wing_workspace.id,
      status_id: 4, status_name: "完了", completed_on: TARGET_DATE - 3
    )
    old_completed = create_task(
      source: "backlog", progress_workspace_id: @wing_workspace.id,
      status_id: 4, status_name: "完了", completed_on: TARGET_DATE - 4
    )

    result_ids = call_query.map(&:id)

    assert_includes result_ids, recent_completed.id
    refute_includes result_ids, old_completed.id
  end

  # 9. 対象日より後に始まるタスクは表示されない
  def test_task_starting_after_target_date_is_excluded
    task = create_task(
      source: "backlog", progress_workspace_id: @wing_workspace.id,
      start_date: TARGET_DATE + 1, created_on: TARGET_DATE + 1
    )

    refute_includes call_query.map(&:id), task.id
  end

  private

  def call_query(assignee: nil)
    TamaCalendarTaskQuery.new(user: @user, date: TARGET_DATE, assignee: assignee).call
  end

  def create_task(source:, progress_workspace_id:, status_id: 1, status_name: "未対応", assignee_name: "西野 鷹也",
                  start_date: TARGET_DATE - 1, created_on: TARGET_DATE - 1, completed_on: nil)
    @user.backlog_tasks.create!(
      issue_key: "TEST-#{SecureRandom.hex(4).upcase}",
      summary: "検証タスク",
      source: source,
      progress_workspace_id: progress_workspace_id,
      status_id: status_id,
      status_name: status_name,
      assignee_name: assignee_name,
      start_date: start_date,
      created_on: created_on,
      completed_on: completed_on
    )
  end
end
