require "test_helper"

# 進捗の外部データソース(Wing=backlog / リビング=notion / テックリーダーズ=trello)は
# 権限を持つ人だけが読める・取り込める・書き込める。権限行が無い人は 403(fail-closed)。
# 「川村さんは Wing とリビングだけ、テックリーダーズは西野さんだけ」を回帰テストとして固定する。
class DataSourceAuthorizationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(email: "admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @kawamura = User.create!(email: "kawamura_#{SecureRandom.hex(4)}@example.com",
                             password: "password123", display_name: "川村 卓也", closing_day: 25)
    @outsider = User.create!(email: "outsider_#{SecureRandom.hex(4)}@example.com",
                             password: "password123", display_name: "岩切 太郎", closing_day: 25)

    @kawamura.user_data_source_permissions.create!(source_type: "backlog", can_view: true, can_sync: true,
                                                   can_write: false, credential_owner_id: @admin.id)
    @kawamura.user_data_source_permissions.create!(source_type: "notion", can_view: true, can_sync: true,
                                                   can_write: true)

    @notion_task = NotionTask.create!(notion_block_id: "block-#{SecureRandom.hex(4)}", title: "リビングのWBS",
                                      synced_at: Time.current)
    @trello_task = TrelloTask.create!(trello_card_id: "card-#{SecureRandom.hex(4)}", title: "テックリーダーズのカード",
                                      synced_at: Time.current)
  end

  def teardown
    @notion_task&.destroy
    @trello_task&.destroy
    [ @admin, @kawamura, @outsider ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  # --- リビング(Notion) ---

  def test_権限の無いユーザーはリビングのタスクを一覧できない
    get "/api/v1/notion_tasks", params: { ignore_date: "true" }, headers: auth_headers(@outsider)

    assert_response :forbidden
  end

  def test_権限の無いユーザーはリビングのメモを書き換えられない
    patch "/api/v1/notion_tasks/#{@notion_task.id}", params: { memo: "勝手に書き換え" },
          headers: auth_headers(@outsider), as: :json

    assert_response :forbidden
    assert_nil @notion_task.reload.memo
  end

  def test_川村さんはリビングのタスクを一覧できる
    get "/api/v1/notion_tasks", params: { ignore_date: "true" }, headers: auth_headers(@kawamura)

    assert_response :success
    assert_includes response.parsed_body.map { |task| task["title"] }, "リビングのWBS"
  end

  # --- テックリーダーズ(Trello) ---

  def test_川村さんはテックリーダーズを一覧できない
    get "/api/v1/trello_tasks", params: { ignore_date: "true" }, headers: auth_headers(@kawamura)

    assert_response :forbidden
  end

  def test_管理者はテックリーダーズを一覧できる
    get "/api/v1/trello_tasks", params: { ignore_date: "true" }, headers: auth_headers(@admin)

    assert_response :success
    assert_includes response.parsed_body.map { |task| task["title"] }, "テックリーダーズのカード"
  end

  # --- Wing(Backlog) ---

  def test_権限の無いユーザーはカレンダーのWingタスクを取得できない
    get "/api/v1/backlog/tasks_on_date", params: { date: "2026-08-21" }, headers: auth_headers(@outsider)

    assert_response :forbidden
  end

  def test_川村さんはカレンダーのWingタスクを取得できる
    get "/api/v1/backlog/tasks_on_date", params: { date: "2026-08-21" }, headers: auth_headers(@kawamura)

    assert_response :success
  end

  def test_書き込み権限が無ければBacklogへコメントできない
    task = @kawamura.backlog_tasks.create!(issue_key: "WING-1", summary: "共有タスク", status_id: 1)

    post "/api/v1/backlog/tasks/#{task.issue_key}/comments", params: { content: "コメント" },
         headers: auth_headers(@kawamura), as: :json

    assert_response :forbidden
  end

  # --- ワークスペース(タブ) ---

  def test_権限の無いソースのワークスペースは一覧に出ない
    get "/api/v1/progress_workspaces", headers: auth_headers(@kawamura)

    assert_response :success
    source_types = response.parsed_body.map { |workspace| workspace["source_type"] }
    assert_includes source_types, "backlog"
    assert_includes source_types, "notion"
    assert_not_includes source_types, "trello", "テックリーダーズのタブは出ない"
    assert_includes source_types, "manual", "ReRe/プライベートは外部連携が無いので常に見える"
  end

  def test_管理者は全ソースのワークスペースが見える
    get "/api/v1/progress_workspaces", headers: auth_headers(@admin)

    assert_response :success
    source_types = response.parsed_body.map { |workspace| workspace["source_type"] }.uniq
    assert_includes source_types, "trello"
  end

  def test_権限の無いソースのワークスペースは作成できない
    post "/api/v1/progress_workspaces", params: { name: "勝手にトレロ", source_type: "trello" },
         headers: auth_headers(@kawamura), as: :json

    assert_response :forbidden
  end

  def test_他人のワークスペースへタスクを移動できない
    ProgressWorkspace.ensure_defaults!(@admin)
    admin_workspace = @admin.progress_workspaces.first
    task = @kawamura.backlog_tasks.create!(issue_key: "WING-2", summary: "自分のタスク", status_id: 1)

    patch "/api/v1/backlog/tasks/#{task.id}", params: { workspace_id: admin_workspace.id },
          headers: auth_headers(@kawamura), as: :json

    assert_response :forbidden
    assert_nil task.reload.progress_workspace_id
  end

  # シート取込は task.progress_workspace_id を書き換えるので、他人のワークスペースを
  # 指定できると他人の箱にタスクを差し込めてしまう。URL検証より先に弾く。
  def test_他人のワークスペースを指定してシート取込できない
    ProgressWorkspace.ensure_defaults!(@admin)
    admin_workspace = @admin.progress_workspaces.first

    post "/api/v1/backlog/import_sheet",
         params: { spreadsheet_url: "https://docs.google.com/spreadsheets/d/DUMMY/edit", workspace_id: admin_workspace.id },
         headers: auth_headers(@kawamura), as: :json

    assert_response :forbidden
  end

  def test_他人のワークスペースを指定してシート書き出しできない
    ProgressWorkspace.ensure_defaults!(@admin)
    admin_workspace = @admin.progress_workspaces.first

    post "/api/v1/backlog/export_sheet",
         params: { spreadsheet_url: "https://docs.google.com/spreadsheets/d/DUMMY/edit", workspace_id: admin_workspace.id },
         headers: auth_headers(@kawamura), as: :json

    assert_response :forbidden
  end

  # 他人のワークスペースのスプレッドシートURLは書き換えられない
  def test_他人のワークスペースのシートURLを更新できない
    ProgressWorkspace.ensure_defaults!(@admin)
    admin_workspace = @admin.progress_workspaces.first

    patch "/api/v1/progress_workspaces/#{admin_workspace.id}",
          params: { sheet_url: "https://docs.google.com/spreadsheets/d/HIJACK/edit" },
          headers: auth_headers(@kawamura), as: :json

    assert_response :not_found
    assert_nil admin_workspace.reload.sheet_url
  end

  # --- 権限の無いワークスペースのタスクは一覧に混ざらない ---

  def test_権限の無いワークスペースのタスクは一覧に出ない
    ProgressWorkspace.ensure_defaults!(@kawamura)
    trello_workspace = @kawamura.progress_workspaces.find_by(source_type: "trello")
    @kawamura.backlog_tasks.create!(issue_key: "TRELLO-1", summary: "見えてはいけないカード", status_id: 1,
                                    progress_workspace_id: trello_workspace.id)
    notion_workspace = @kawamura.progress_workspaces.find_by(source_type: "notion")
    @kawamura.backlog_tasks.create!(issue_key: "LIVING-1", summary: "見えてよいタスク", status_id: 1,
                                    progress_workspace_id: notion_workspace.id)

    get "/api/v1/backlog/tasks", headers: auth_headers(@kawamura)

    assert_response :success
    summaries = response.parsed_body.map { |task| task["summary"] }
    assert_includes summaries, "見えてよいタスク"
    assert_not_includes summaries, "見えてはいけないカード"
  end
end
