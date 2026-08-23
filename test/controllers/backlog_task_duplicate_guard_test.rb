require "test_helper"

# 進捗管理の「追加」ボタンが連打されると POST /backlog/tasks が同時に何本も飛び、
# 同じ Todo が人数分できてしまう(2026-08-22 にプライベートTodoが5件・Googleカレンダーに
# 同じ予定が5件登録された)。直近の同一タイトルは作り直さず既存を返すことを固定する。
class BacklogTaskDuplicateGuardTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "duplicate_guard_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @workspace = @user.progress_workspaces.create!(name: "テスト用", source_type: "manual", position: 0)
  end

  def teardown
    @user&.destroy
  end

  def auth_headers
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(@user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def create_task(summary:, workspace: @workspace)
    post "/api/v1/backlog/tasks", params: { summary: summary, workspace_id: workspace.id },
         headers: auth_headers, as: :json
  end

  def test_連打しても同じタイトルのTodoは1件しか作られない
    5.times { create_task(summary: "8/25 経営者勉強会 参加表明") }

    assert_response :created
    assert_equal 1, @user.backlog_tasks.where(summary: "8/25 経営者勉強会 参加表明").count
  end

  def test_連打の2回目以降は1件目のTodoをそのまま返す
    create_task(summary: "8/25 経営者勉強会 参加表明")
    first_id = response.parsed_body["id"]

    create_task(summary: "8/25 経営者勉強会 参加表明")

    assert_response :created
    assert_equal first_id, response.parsed_body["id"]
  end

  def test_タイトルが違えば別のTodoとして作られる
    create_task(summary: "8/25 経営者勉強会 参加表明")
    create_task(summary: "8/26 請求書の送付")

    assert_equal 2, @user.backlog_tasks.count
  end

  def test_ワークスペースが違えば別のTodoとして作られる
    another_workspace = @user.progress_workspaces.create!(name: "テスト用2", source_type: "manual", position: 1)

    create_task(summary: "8/25 経営者勉強会 参加表明")
    create_task(summary: "8/25 経営者勉強会 参加表明", workspace: another_workspace)

    assert_equal 2, @user.backlog_tasks.count
  end

  def test_猶予時間を過ぎていれば同じタイトルでも作り直せる
    create_task(summary: "毎週の定例")
    @user.backlog_tasks.update_all(created_at: (Api::V1::BacklogController::DUPLICATE_TASK_WINDOW + 1.second).ago)

    create_task(summary: "毎週の定例")

    assert_equal 2, @user.backlog_tasks.where(summary: "毎週の定例").count
  end
end
