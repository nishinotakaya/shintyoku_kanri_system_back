require "test_helper"

# Api::V1::BacklogActivitiesController の Notion(WBS) タスク追加・削除・WBSレベル編集。
#   POST   /backlog_activities/notion_task  基準行の下に手動タスクを追加(WBSレベルは基準行の子の次番号)
#   DELETE /backlog_activities/notion_task  手動追加(manual)タスクだけ削除できる
#   PATCH  /backlog_activities/notion_task  wbs_level は manual 行のみ反映
class Api::V1::BacklogActivitiesNotionTaskTest < ActionDispatch::IntegrationTest
  ENDPOINT = "/api/v1/backlog_activities/notion_task".freeze

  def setup
    @admin = User.create!(email: User::ADMIN_EMAILS.first, password: "password123",
                          display_name: "西野 鷹也", closing_day: 25)
    @plain_user = User.create!(email: "notion_task_plain_#{SecureRandom.hex(4)}@example.com", password: "password123",
                               display_name: "権限なし 太郎", feature_flags: { "backlog_activities" => true })
    @created_task_ids = []
  end

  def teardown
    NotionTask.where(id: @created_task_ids).delete_all
    NotionTask.where("notion_block_id LIKE 'manual-%'").delete_all
    [ @admin, @plain_user ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def create_notion_task(wbs_level:, **attributes)
    task = NotionTask.create!(
      { notion_block_id: SecureRandom.uuid, wbs_level: wbs_level, title: "タスク#{wbs_level}",
        assignee_name: "担当A", synced_at: Time.current }.merge(attributes)
    )
    @created_task_ids << task.id
    task
  end

  # ---- AC-01 POST ----

  def test_create_assigns_next_child_wbs_level_and_copies_assignee
    base_task = create_notion_task(wbs_level: "1.2", assignee_name: "担当A")
    create_notion_task(wbs_level: "1.2.1")
    create_notion_task(wbs_level: "1.2.2")

    assert_difference -> { NotionTask.count }, 1 do
      post ENDPOINT, params: { after_notion_block_id: base_task.notion_block_id },
                     headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["ok"]
    created_task = NotionTask.find_by!(notion_block_id: body["created_notion_block_id"])
    assert_equal "1.2.3", created_task.wbs_level
    assert_equal true, created_task.manual
    assert body["created_notion_block_id"].start_with?("manual-")
    assert_equal "新規タスク", created_task.title
    assert_equal "担当A", created_task.assignee_name
    created_option = body["notion_tasks"].find { |option| option["notion_block_id"] == body["created_notion_block_id"] }
    assert_equal true, created_option["manual"]
    assert body["notion_tasks"].all? { |option| option.key?("manual") }
  end

  def test_create_prefers_assignee_name_prev_of_base_task
    base_task = create_notion_task(wbs_level: "3", assignee_name: "担当A", assignee_name_prev: "担当B")

    post ENDPOINT, params: { after_notion_block_id: base_task.notion_block_id },
                   headers: auth_headers(@admin), as: :json

    assert_response :success
    created_task = NotionTask.find_by!(notion_block_id: response.parsed_body["created_notion_block_id"])
    assert_equal "担当B", created_task.assignee_name
    assert_equal "3.1", created_task.wbs_level
  end

  def test_create_starts_at_one_when_base_task_has_no_children
    base_task = create_notion_task(wbs_level: "1.2")
    create_notion_task(wbs_level: "1.3.1") # 別系統の子は数えない

    post ENDPOINT, params: { after_notion_block_id: base_task.notion_block_id },
                   headers: auth_headers(@admin), as: :json

    assert_response :success
    created_task = NotionTask.find_by!(notion_block_id: response.parsed_body["created_notion_block_id"])
    assert_equal "1.2.1", created_task.wbs_level
  end

  def test_create_without_base_task_has_nil_wbs_level
    assert_difference -> { NotionTask.count }, 1 do
      post ENDPOINT, headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    created_task = NotionTask.find_by!(notion_block_id: response.parsed_body["created_notion_block_id"])
    assert_nil created_task.wbs_level
    assert_equal true, created_task.manual
  end

  def test_create_with_blank_wbs_level_base_task_has_nil_wbs_level
    base_task = create_notion_task(wbs_level: nil)

    post ENDPOINT, params: { after_notion_block_id: base_task.notion_block_id },
                   headers: auth_headers(@admin), as: :json

    assert_response :success
    created_task = NotionTask.find_by!(notion_block_id: response.parsed_body["created_notion_block_id"])
    assert_nil created_task.wbs_level
  end

  def test_create_is_forbidden_for_user_without_permission_on_target_user
    assert_no_difference -> { NotionTask.count } do
      post ENDPOINT, params: { user_id: @admin.id }, headers: auth_headers(@plain_user), as: :json
    end

    assert_response :forbidden
  end

  # ---- AC-02 DELETE ----

  def test_destroy_removes_manual_task
    manual_task = create_notion_task(wbs_level: "1.1", notion_block_id: "manual-#{SecureRandom.uuid}", manual: true)

    assert_difference -> { NotionTask.count }, -1 do
      delete ENDPOINT, params: { notion_block_id: manual_task.notion_block_id },
                       headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["ok"]
    assert_nil NotionTask.find_by(id: manual_task.id)
    assert_nil body["notion_tasks"].find { |option| option["notion_block_id"] == manual_task.notion_block_id }
  end

  def test_destroy_rejects_notion_derived_task
    notion_task = create_notion_task(wbs_level: "1.1")

    assert_no_difference -> { NotionTask.count } do
      delete ENDPOINT, params: { notion_block_id: notion_task.notion_block_id },
                       headers: auth_headers(@admin), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "Notion 由来のタスクは削除できません", response.parsed_body["error"]
    assert NotionTask.exists?(notion_task.id)
  end

  # ---- AC-03 PATCH wbs_level ----

  def test_update_changes_wbs_level_only_for_manual_task
    manual_task = create_notion_task(wbs_level: "1.1", notion_block_id: "manual-#{SecureRandom.uuid}", manual: true)

    patch ENDPOINT, params: { notion_block_id: manual_task.notion_block_id, wbs_level: "9.9" },
                    headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_equal "9.9", manual_task.reload.wbs_level
  end

  def test_update_ignores_wbs_level_for_notion_derived_task
    notion_task = create_notion_task(wbs_level: "1.1")

    patch ENDPOINT, params: { notion_block_id: notion_task.notion_block_id, wbs_level: "9.9", title_prev: "直した" },
                    headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_equal "1.1", notion_task.reload.wbs_level
    assert_equal "直した", notion_task.title_prev # 他の項目は従来どおり反映
  end

  # ---- 追加ケース ----

  def test_create_ignores_grandchildren_and_lookalike_siblings_when_numbering
    base_task = create_notion_task(wbs_level: "1.2")
    %w[1.2.1 1.2.1.1 1.20.1 1.20.5].each { |wbs_level| create_notion_task(wbs_level: wbs_level) }

    post ENDPOINT, params: { after_notion_block_id: base_task.notion_block_id },
                   headers: auth_headers(@admin), as: :json

    assert_response :success
    created_task = NotionTask.find_by!(notion_block_id: response.parsed_body["created_notion_block_id"])
    assert_equal "1.2.2", created_task.wbs_level
  end

  def test_create_returns_not_found_when_base_task_does_not_exist
    assert_no_difference -> { NotionTask.count } do
      post ENDPOINT, params: { after_notion_block_id: "missing-#{SecureRandom.uuid}" },
                     headers: auth_headers(@admin), as: :json
    end

    assert_response :not_found
  end

  def test_destroy_returns_not_found_for_unknown_notion_block_id
    assert_no_difference -> { NotionTask.count } do
      delete ENDPOINT, params: { notion_block_id: "manual-#{SecureRandom.uuid}" },
                       headers: auth_headers(@admin), as: :json
    end

    assert_response :not_found
  end

  def test_destroy_is_forbidden_for_user_without_permission_on_target_user
    manual_task = create_notion_task(wbs_level: "1.1", notion_block_id: "manual-#{SecureRandom.uuid}", manual: true)

    assert_no_difference -> { NotionTask.count } do
      delete ENDPOINT, params: { notion_block_id: manual_task.notion_block_id, user_id: @admin.id },
                       headers: auth_headers(@plain_user), as: :json
    end

    assert_response :forbidden
    assert NotionTask.exists?(manual_task.id)
  end

  def test_update_is_forbidden_for_user_without_permission_on_target_user
    manual_task = create_notion_task(wbs_level: "1.1", notion_block_id: "manual-#{SecureRandom.uuid}", manual: true)

    patch ENDPOINT, params: { notion_block_id: manual_task.notion_block_id, wbs_level: "9.9", user_id: @admin.id },
                    headers: auth_headers(@plain_user), as: :json

    assert_response :forbidden
    assert_equal "1.1", manual_task.reload.wbs_level
  end
end
