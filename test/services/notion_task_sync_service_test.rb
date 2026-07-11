require "test_helper"

# NotionTaskSyncService: NotionTask 全件を builtin「リビング」ワークスペースへ upsert する。
# ステータスのマッピングと、2回実行しても件数が増えない(upsert)ことを検証する。
class NotionTaskSyncServiceTest < Minitest::Test
  def setup
    @user = User.create!(
      email: "notion_sync_owner_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "Notion同期所有者"
    )
    @notion_tasks = []
  end

  def teardown
    @notion_tasks.each(&:destroy)
    @user&.destroy
  end

  # 1. status="完了" は status_id=4, status_name="完了" にマップされる
  def test_status_kanryou_maps_to_status_id_4
    create_notion_task(status: "完了")

    NotionTaskSyncService.new(@user).call

    task = @user.backlog_tasks.find_by!(source: "notion")
    assert_equal 4, task.status_id
    assert_equal "完了", task.status_name
  end

  # 2. status="進行中" は status_id=2, status_name="処理中" にマップされる
  def test_status_shinkouchuu_maps_to_status_id_2
    create_notion_task(status: "進行中")

    NotionTaskSyncService.new(@user).call

    task = @user.backlog_tasks.find_by!(source: "notion")
    assert_equal 2, task.status_id
    assert_equal "処理中", task.status_name
  end

  # 3. status が "未着手"/nil/その他 のいずれも status_id=1, status_name="未対応" にマップされる
  def test_status_others_map_to_status_id_1
    [ "未着手", nil, "保留" ].each do |status_value|
      notion_task = create_notion_task(status: status_value)

      NotionTaskSyncService.new(@user).call

      task = @user.backlog_tasks.find_by!(source: "notion", issue_key: "N-#{notion_task.notion_block_id.first(8)}")
      assert_equal 1, task.status_id, "status=#{status_value.inspect} は status_id=1 になるべき"
      assert_equal "未対応", task.status_name
    end
  end

  # 4. summary/memo/assignee_name/start_date/end_date/progress_value が Notion 側から反映される
  def test_upserted_task_fields_are_mapped_from_notion_task
    notion_task = create_notion_task(
      title: "画面設計",
      note: "詳細メモ",
      assignee_name: "山田太郎",
      start_date: Date.new(2026, 7, 1),
      end_date: Date.new(2026, 7, 15),
      progress_rate: 0.5
    )

    NotionTaskSyncService.new(@user).call

    task = @user.backlog_tasks.find_by!(source: "notion", issue_key: "N-#{notion_task.notion_block_id.first(8)}")
    assert_equal "画面設計", task.summary
    assert_equal "詳細メモ", task.memo
    assert_equal "山田太郎", task.assignee_name
    assert_equal Date.new(2026, 7, 1), task.start_date
    assert_equal Date.new(2026, 7, 15), task.end_date
    assert_equal 0.5, task.progress_value
  end

  # 5. 保存先は builtin の「リビング」ワークスペース
  def test_upserted_task_belongs_to_living_workspace
    create_notion_task

    NotionTaskSyncService.new(@user).call

    living_workspace = @user.progress_workspaces.find_by!(builtin: true, source_type: "notion")
    task = @user.backlog_tasks.find_by!(source: "notion")
    assert_equal living_workspace.id, task.progress_workspace_id
  end

  # 6. 2回実行しても件数が増えない(issue_key で upsert される)
  def test_running_twice_does_not_duplicate_tasks
    create_notion_task

    NotionTaskSyncService.new(@user).call
    first_count = @user.backlog_tasks.where(source: "notion").count
    NotionTaskSyncService.new(@user).call
    second_count = @user.backlog_tasks.where(source: "notion").count

    assert_equal 1, first_count
    assert_equal first_count, second_count
  end

  # 7. call の戻り値は同期件数
  def test_call_returns_synced_count
    create_notion_task
    create_notion_task

    synced = NotionTaskSyncService.new(@user).call

    assert_equal 2, synced
  end

  private

  def create_notion_task(title: "テストタスク", note: nil, assignee_name: nil, start_date: nil, end_date: nil, progress_rate: nil, status: nil)
    task = NotionTask.create!(
      notion_block_id: SecureRandom.hex(16),
      title: title,
      note: note,
      assignee_name: assignee_name,
      start_date: start_date,
      end_date: end_date,
      progress_rate: progress_rate,
      status: status,
      synced_at: Time.current
    )
    @notion_tasks << task
    task
  end
end
