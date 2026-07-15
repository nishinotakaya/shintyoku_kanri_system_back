require "test_helper"

# TrelloTaskSyncService: TrelloTask 全件を builtin「テックリーダーズ」ワークスペース(source_type: "trello")へ upsert する。
# ステータスのマッピングと、2回実行しても件数が増えない(upsert)ことを検証する。
class TrelloTaskSyncServiceTest < Minitest::Test
  def setup
    @user = User.create!(
      email: "trello_sync_owner_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "Trello同期所有者"
    )
    @trello_tasks = []
  end

  def teardown
    @trello_tasks.each(&:destroy)
    @user&.destroy
  end

  # 1. TrelloTask が builtin テックリーダーズ(source_type: "trello")ワークスペースの BacklogTask に
  #    issue_key "T-<card_id>", source "trello" で upsert される
  def test_trello_task_is_upserted_into_backlog_task_with_expected_issue_key_and_source
    trello_task = create_trello_task(trello_card_id: "card-abc123")

    TrelloTaskSyncService.new(@user).call

    task = @user.backlog_tasks.find_by!(source: "trello", issue_key: "T-card-abc123")
    refute_nil task
    assert_equal trello_task.title, task.summary

    tech_leaders_workspace = @user.progress_workspaces.find_by!(builtin: true, source_type: "trello")
    assert_equal tech_leaders_workspace.id, task.progress_workspace_id
  end

  # 2-a. list_name「main マージ」は status_id=4(完了) にマップされる
  def test_list_name_main_merge_maps_to_status_id_4
    create_trello_task(list_name: "main マージ")

    TrelloTaskSyncService.new(@user).call

    task = @user.backlog_tasks.find_by!(source: "trello")
    assert_equal 4, task.status_id
    assert_equal "完了", task.status_name
  end

  # 2-b. list_name「develop検証完了」「本番検証中」は status_id=3(処理済) にマップされる
  def test_list_name_kenshou_maps_to_status_id_3
    [ "develop検証完了", "本番検証中" ].each do |list_name_value|
      trello_task = create_trello_task(list_name: list_name_value)

      TrelloTaskSyncService.new(@user).call

      task = @user.backlog_tasks.find_by!(source: "trello", issue_key: "T-#{trello_task.trello_card_id}")
      assert_equal 3, task.status_id, "list_name=#{list_name_value.inspect} は status_id=3 になるべき"
      assert_equal "処理済", task.status_name
    end
  end

  # 2-c. list_name「プルリク(レビュー依頼)」「ドラフトプルリク(WIP_作業中)」は status_id=2(処理中) にマップされる
  def test_list_name_pull_request_maps_to_status_id_2
    [ "プルリク(レビュー依頼)", "ドラフトプルリク(WIP_作業中)" ].each do |list_name_value|
      trello_task = create_trello_task(list_name: list_name_value)

      TrelloTaskSyncService.new(@user).call

      task = @user.backlog_tasks.find_by!(source: "trello", issue_key: "T-#{trello_task.trello_card_id}")
      assert_equal 2, task.status_id, "list_name=#{list_name_value.inspect} は status_id=2 になるべき"
      assert_equal "処理中", task.status_name
    end
  end

  # 2-d. list_name がその他(未着手/nil/未知のリスト名/「MTGで確認タスク、話し合い事項」)は status_id=1 にマップされる
  def test_list_name_others_map_to_status_id_1
    [ "未着手", nil, "解説リスト", "MTGで確認タスク、話し合い事項" ].each do |list_name_value|
      trello_task = create_trello_task(list_name: list_name_value)

      TrelloTaskSyncService.new(@user).call

      task = @user.backlog_tasks.find_by!(source: "trello", issue_key: "T-#{trello_task.trello_card_id}")
      assert_equal 1, task.status_id, "list_name=#{list_name_value.inspect} は status_id=1 になるべき"
      assert_equal "未対応", task.status_name
    end
  end

  # 2-e. list_name「ゴミ箱 タスク」のカードは BacklogTask に取り込まれない
  def test_list_name_gomibako_is_skipped
    create_trello_task(list_name: "ゴミ箱 タスク")

    synced = TrelloTaskSyncService.new(@user).call

    assert_equal 0, synced
    refute @user.backlog_tasks.where(source: "trello").exists?
  end

  # 2-f. 「ゴミ箱」に移動したカードは、既存の BacklogTask があれば削除される
  def test_list_name_gomibako_deletes_existing_backlog_task
    trello_task = create_trello_task(list_name: "作業中")
    TrelloTaskSyncService.new(@user).call
    assert @user.backlog_tasks.where(source: "trello", issue_key: "T-#{trello_task.trello_card_id}").exists?

    trello_task.update!(list_name: "ゴミ箱 タスク")
    TrelloTaskSyncService.new(@user).call

    refute @user.backlog_tasks.where(source: "trello", issue_key: "T-#{trello_task.trello_card_id}").exists?
  end

  # 3. 同じカードの再同期で BacklogTask が重複しない(issue_key で upsert される)
  def test_running_twice_does_not_duplicate_tasks
    create_trello_task

    TrelloTaskSyncService.new(@user).call
    first_count = @user.backlog_tasks.where(source: "trello").count
    TrelloTaskSyncService.new(@user).call
    second_count = @user.backlog_tasks.where(source: "trello").count

    assert_equal 1, first_count
    assert_equal first_count, second_count
  end

  # 4. summary/memo/assignee_name/start_date/end_date/url が TrelloTask 側から反映される
  def test_upserted_task_fields_are_mapped_from_trello_task
    trello_task = create_trello_task(
      title: "画面設計",
      description: "詳細メモ",
      assignee_name: "山田太郎",
      start_date: Date.new(2026, 7, 1),
      due_date: Date.new(2026, 7, 15),
      url: "https://trello.com/c/abc123"
    )

    TrelloTaskSyncService.new(@user).call

    task = @user.backlog_tasks.find_by!(source: "trello", issue_key: "T-#{trello_task.trello_card_id}")
    assert_equal "画面設計", task.summary
    assert_equal "詳細メモ", task.memo
    assert_equal "山田太郎", task.assignee_name
    assert_equal Date.new(2026, 7, 1), task.start_date
    assert_equal Date.new(2026, 7, 15), task.end_date
    assert_equal "https://trello.com/c/abc123", task.url
  end

  # 5. call の戻り値は同期件数
  def test_call_returns_synced_count
    create_trello_task
    create_trello_task

    synced = TrelloTaskSyncService.new(@user).call

    assert_equal 2, synced
  end

  private

  def create_trello_task(trello_card_id: SecureRandom.hex(8), title: "テストタスク", description: nil, list_name: nil, assignee_name: nil, start_date: nil, due_date: nil, url: nil)
    task = TrelloTask.create!(
      trello_card_id: trello_card_id,
      title: title,
      description: description,
      list_name: list_name,
      assignee_name: assignee_name,
      start_date: start_date,
      due_date: due_date,
      url: url,
      synced_at: Time.current
    )
    @trello_tasks << task
    task
  end
end
