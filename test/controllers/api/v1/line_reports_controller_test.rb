require "test_helper"

# Api::V1::LineReportsController: 組み立て済み文面の LINE 送信(汎用)。
# notion_issue_keys 付きなら送信後に NotionTask の変更差分(*_prev)をクリアする。
# 実際の LINE 送信はスタブし、テストから外部送信しない。
class Api::V1::LineReportsControllerTest < ActionDispatch::IntegrationTest
  def setup
    # シート同期(Google Sheets)はテストから外部送信しない
    @original_sheet_sync = LineReportSheetSync.method(:sync)
    LineReportSheetSync.define_singleton_method(:sync) { |operator:, month:| { sheet: "stub", rows: 0 } }
    suffix = SecureRandom.hex(4)
    @admin = User.create!(email: "line_admin_#{suffix}@example.com", password: "password123",
                          display_name: "西野 鷹也", closing_day: 25)
    @plain_user = User.create!(email: "line_plain_#{suffix}@example.com", password: "password123",
                               display_name: "権限なし 太郎", closing_day: 25)
    @task = NotionTask.create!(notion_block_id: SecureRandom.uuid, title: "汎用LINEテスト_#{suffix}",
                               start_date: Date.new(2026, 9, 15), start_date_prev: Date.new(2026, 9, 10),
                               synced_at: Time.current)
    @issue_key = "N-#{@task.notion_block_id.delete('-')}"
  end

  def teardown
    LineReportSheetSync.define_singleton_method(:sync, @original_sheet_sync)
    @task&.destroy
    [ @admin, @plain_user ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def with_line_notifier_stub(result: true)
    sent_texts = []
    original_push = LineNotifier.method(:push)
    LineNotifier.define_singleton_method(:push) { |text| sent_texts << text; result }
    yield sent_texts
  ensure
    LineNotifier.define_singleton_method(:push, original_push)
  end

  def test_sends_the_given_message
    sent_texts = nil
    with_line_notifier_stub do |texts|
      sent_texts = texts
      post "/api/v1/line_reports", params: { message: "📋 進捗報告\n\nタスク: SAP-1 テスト" },
           headers: auth_headers(@plain_user), as: :json
    end

    assert_response :success
    assert_equal [ "📋 進捗報告\n\nタスク: SAP-1 テスト" ], sent_texts
  end

  def test_records_line_report_entries_for_the_sheet
    with_line_notifier_stub do
      post "/api/v1/line_reports", params: { message: "タスク: シート連携\n進捗率: 40%" },
           headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    assert_equal true, response.parsed_body["sheet_synced"]
    entry = LineReportEntry.find_by(user_id: @admin.id, reported_on: Time.zone.today, task_title: "シート連携")
    assert_equal "40%", entry&.progress_text
  ensure
    LineReportEntry.where(user_id: @admin.id).delete_all
  end

  def test_blank_message_is_rejected
    post "/api/v1/line_reports", params: { message: "  " }, headers: auth_headers(@admin), as: :json

    assert_response :unprocessable_entity
  end

  def test_clears_notion_diffs_when_issue_keys_are_given
    with_line_notifier_stub do
      post "/api/v1/line_reports", params: { message: "報告", notion_issue_keys: [ @issue_key ] },
           headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    assert_nil @task.reload.start_date_prev
  end

  def test_does_not_clear_notion_diffs_without_notion_permission
    with_line_notifier_stub do
      post "/api/v1/line_reports", params: { message: "報告", notion_issue_keys: [ @issue_key ] },
           headers: auth_headers(@plain_user), as: :json
    end

    assert_response :success
    assert_equal Date.new(2026, 9, 10), @task.reload.start_date_prev
  end

  def test_failure_returns_bad_gateway
    with_line_notifier_stub(result: false) do
      post "/api/v1/line_reports", params: { message: "報告" }, headers: auth_headers(@admin), as: :json
    end

    assert_response :bad_gateway
  end
end
