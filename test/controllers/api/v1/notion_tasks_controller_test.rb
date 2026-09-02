require "test_helper"

# Api::V1::NotionTasksController#line_report(_preview):
# リビング(Notion)タスクの進捗を LINE で報告する。notion の view 権限が必要。
# 送信後は *_prev(変更差分)がクリアされる。実際の LINE 送信はスタブし、テストから外部送信しない。
class Api::V1::NotionTasksControllerTest < ActionDispatch::IntegrationTest
  def setup
    suffix = SecureRandom.hex(4)
    @admin = User.create!(email: "notion_admin_#{suffix}@example.com", password: "password123",
                          display_name: "西野 鷹也", closing_day: 25)
    @plain_user = User.create!(email: "notion_plain_#{suffix}@example.com", password: "password123",
                               display_name: "権限なし 太郎", closing_day: 25)
    @task = NotionTask.create!(notion_block_id: SecureRandom.uuid, title: "LINE報告テスト_#{suffix}",
                               wbs_level: "1.2.3", start_date: Date.new(2026, 9, 15),
                               start_date_prev: Date.new(2026, 9, 10),
                               progress_rate: 0.9, progress_rate_prev: 0.7, synced_at: Time.current)
    @issue_key = "N-#{@task.notion_block_id.delete('-')}"
  end

  def teardown
    @task&.destroy
    [ @admin, @plain_user ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  # LineNotifier.push を差し替えて、テストから実際の LINE 送信をしない。
  # ブロックには送信された本文の配列を渡す。
  def with_line_notifier_stub(result: true)
    sent_texts = []
    original_push = LineNotifier.method(:push)
    LineNotifier.define_singleton_method(:push) { |text| sent_texts << text; result }
    yield sent_texts
  ensure
    LineNotifier.define_singleton_method(:push, original_push)
  end

  def test_preview_builds_the_message_without_sending
    post "/api/v1/notion_tasks/line_report_preview", params: { issue_keys: [ @issue_key ] },
         headers: auth_headers(@admin), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["task_count"]
    assert_includes body["message"], "開始日: 2026/09/10 → 9/15"
    assert_includes body["message"], "進捗率: 70% → 90%"
    # プレビューでは差分はクリアされない
    assert_equal Date.new(2026, 9, 10), @task.reload.start_date_prev
  end

  def test_line_report_sends_and_clears_the_diffs
    sent_texts = nil
    with_line_notifier_stub do |texts|
      sent_texts = texts
      post "/api/v1/notion_tasks/line_report", params: { issue_keys: [ @issue_key ] },
           headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    assert_equal 1, sent_texts.size
    assert_includes sent_texts.first, "進捗率: 70% → 90%"
    @task.reload
    assert_nil @task.start_date_prev
    assert_nil @task.progress_rate_prev
    assert_equal Date.new(2026, 9, 15), @task.start_date
  end

  def test_line_report_uses_the_edited_message_when_given
    sent_texts = nil
    with_line_notifier_stub do |texts|
      sent_texts = texts
      post "/api/v1/notion_tasks/line_report",
           params: { issue_keys: [ @issue_key ], message: "編集済みの報告です" },
           headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    assert_equal [ "編集済みの報告です" ], sent_texts
  end

  def test_line_report_failure_returns_bad_gateway_and_keeps_diffs
    with_line_notifier_stub(result: false) do
      post "/api/v1/notion_tasks/line_report", params: { issue_keys: [ @issue_key ] },
           headers: auth_headers(@admin), as: :json
    end

    assert_response :bad_gateway
    assert_equal Date.new(2026, 9, 10), @task.reload.start_date_prev
  end

  def test_unknown_issue_keys_are_rejected
    post "/api/v1/notion_tasks/line_report", params: { issue_keys: [ "N-deadbeef" ] },
         headers: auth_headers(@admin), as: :json

    assert_response :unprocessable_entity
  end

  def test_user_without_notion_permission_is_forbidden
    post "/api/v1/notion_tasks/line_report", params: { issue_keys: [ @issue_key ] },
         headers: auth_headers(@plain_user), as: :json

    assert_response :forbidden
  end
end
