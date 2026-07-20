require "test_helper"

# ProgressWorkspace: 進捗管理(/progress)のワークスペース切替機能。
# デフォルト5個(Wing/リビング/テックリーダーズ/ReRe/プライベート)の生成と、
# 削除ガード(builtin/タスク残存)が依拠する条件を検証する。
class ProgressWorkspaceTest < Minitest::Test
  def setup
    @user = User.create!(
      email: "progress_workspace_owner_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "進捗ワークスペース所有者"
    )
  end

  def teardown
    @user&.destroy
  end

  # 1. ensure_defaults! は builtin が無ければデフォルト5個を position 順に作成する
  def test_ensure_defaults_creates_five_builtin_workspaces_in_order
    ProgressWorkspace.ensure_defaults!(@user)

    workspaces = @user.progress_workspaces.order(:position)
    assert_equal 5, workspaces.size
    assert_equal [ "Wing", "リビング", "テックリーダーズ", "ReRe", "プライベート" ], workspaces.map(&:name)
    assert_equal [ "backlog", "notion", "trello", "manual", "manual" ], workspaces.map(&:source_type)
    assert workspaces.all?(&:builtin?), "デフォルトワークスペースは全て builtin であるべき"
  end

  # 2. ensure_defaults! は冪等: 2回呼んでも重複作成されない
  def test_ensure_defaults_is_idempotent
    ProgressWorkspace.ensure_defaults!(@user)
    ProgressWorkspace.ensure_defaults!(@user)

    assert_equal 5, @user.progress_workspaces.count
  end

  # 3. as_payload はワークスペース情報を返す
  def test_as_payload_returns_expected_keys
    ProgressWorkspace.ensure_defaults!(@user)
    wing = @user.progress_workspaces.find_by!(name: "Wing")

    payload = wing.as_payload

    assert_equal wing.id, payload[:id]
    assert_equal "Wing", payload[:name]
    assert_equal "backlog", payload[:source_type]
    assert_equal true, payload[:builtin]
    assert_equal 0, payload[:position]
  end

  # 4. destroy ガードの前提条件: builtin フラグはコントローラの削除拒否判定に使われる
  def test_builtin_flag_is_true_for_default_workspaces
    ProgressWorkspace.ensure_defaults!(@user)
    living = @user.progress_workspaces.find_by!(name: "リビング")

    assert living.builtin?, "デフォルトのリビングは builtin であるべき(削除拒否の対象)"
  end

  # 5. destroy ガードの前提条件: タスクが残っていれば backlog_tasks.exists? が true になる
  def test_backlog_tasks_exists_when_task_belongs_to_workspace
    custom_workspace = @user.progress_workspaces.create!(name: "自作ワークスペース", source_type: "manual", position: 10)
    refute custom_workspace.backlog_tasks.exists?, "タスクが無い段階では false であるべき"

    @user.backlog_tasks.create!(issue_key: "LOCAL-TEST1", summary: "テストタスク", status_id: 1, status_name: "未対応", progress_workspace: custom_workspace)

    assert custom_workspace.backlog_tasks.exists?, "タスクが所属していれば true であるべき"
  end

  # 6. ワークスペースを削除すると所属タスクは progress_workspace_id が nil になる(dependent: :nullify)
  def test_destroying_workspace_nullifies_backlog_tasks
    custom_workspace = @user.progress_workspaces.create!(name: "退避先", source_type: "manual", position: 11)
    task = @user.backlog_tasks.create!(issue_key: "LOCAL-TEST2", summary: "退避対象タスク", status_id: 1, status_name: "未対応", progress_workspace: custom_workspace)

    custom_workspace.destroy!

    assert_nil task.reload.progress_workspace_id
  end
end
