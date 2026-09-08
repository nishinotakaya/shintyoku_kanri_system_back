require "test_helper"
require "zip"

# Api::V1::BacklogActivitiesController の WBS Excel(受領xlsm)テンプレート登録/書き出し。
#   GET  /backlog_activities/wbs_excel_template  登録状況の確認
#   POST /backlog_activities/wbs_excel_template  テンプレート登録(全体で1件のみ保持)
#   GET  /backlog_activities/wbs_excel_export    Notion(WBS) タスクを反映した xlsm を書き出す
#   POST /backlog_activities/wbs_excel_import    ISN側が編集したExcel(.xlsx/.xlsm)を取り込む
class Api::V1::BacklogActivitiesWbsExcelTest < ActionDispatch::IntegrationTest
  TEMPLATE_PATH = Rails.root.join("test/fixtures/files/wbs_schedule_template.xlsm")

  def setup
    @admin = User.create!(email: User::ADMIN_EMAILS.first, password: "password123",
                          display_name: "西野 鷹也", closing_day: 25)
    @plain_user = User.create!(email: "wbs_plain_#{SecureRandom.hex(4)}@example.com", password: "password123",
                               display_name: "権限なし 太郎", feature_flags: { "backlog_activities" => true })
    @notion_tasks = []
  end

  def teardown
    @notion_tasks.each(&:destroy)
    WbsExcelTemplate.delete_all
    [ @admin, @plain_user ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_export_returns_not_found_when_template_is_not_registered
    get "/api/v1/backlog_activities/wbs_excel_export", headers: auth_headers(@admin)

    assert_response :not_found
    assert_equal "Excel テンプレートが未登録です", response.parsed_body["error"]
  end

  def test_template_returns_null_when_not_registered
    get "/api/v1/backlog_activities/wbs_excel_template", headers: auth_headers(@admin)

    assert_response :success
    assert_nil response.parsed_body["template"]
  end

  def test_upload_registers_template_and_returns_schedule_header
    post "/api/v1/backlog_activities/wbs_excel_template",
         params: { file: uploaded_template_file },
         headers: auth_headers(@admin)

    assert_response :success
    template = response.parsed_body["template"]
    assert_equal "wbs_schedule_template.xlsm", template["file_name"]
    assert_equal "西野 鷹也", template["uploaded_by_name"]
    assert_equal "WBS（フェーズ1：現行機能の刷新）", template["project_title"]
    assert_equal "ダミー会社", template["company_name"]
    assert_equal "2026-08-10", template["project_start"]
    assert_equal 1, WbsExcelTemplate.count
  end

  def test_upload_is_forbidden_for_non_admin_non_sub_admin
    post "/api/v1/backlog_activities/wbs_excel_template",
         params: { file: uploaded_template_file },
         headers: auth_headers(@plain_user)

    assert_response :forbidden
    assert_equal "管理者のみ実行できます", response.parsed_body["error"]
    assert_equal 0, WbsExcelTemplate.count
  end

  def test_upload_rejects_non_xlsm_extension
    Tempfile.create([ "template", ".xlsx" ]) do |file|
      File.binwrite(file.path, File.binread(TEMPLATE_PATH))
      post "/api/v1/backlog_activities/wbs_excel_template",
           params: { file: Rack::Test::UploadedFile.new(file.path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") },
           headers: auth_headers(@admin)
    end

    assert_response :unprocessable_entity
    assert_match(/xlsm/, response.parsed_body["error"])
    assert_equal 0, WbsExcelTemplate.count
  end

  def test_upload_rejects_file_without_the_expected_sheet
    invalid_bytes = build_zip_without_schedule_sheet
    Tempfile.create([ "invalid_wbs", ".xlsm" ]) do |file|
      File.binwrite(file.path, invalid_bytes)
      post "/api/v1/backlog_activities/wbs_excel_template",
           params: { file: Rack::Test::UploadedFile.new(file.path, "application/vnd.ms-excel.sheet.macroEnabled.12") },
           headers: auth_headers(@admin)
    end

    assert_response :unprocessable_entity
    assert_match(/プロジェクトのスケジュール/, response.parsed_body["error"])
  end

  def test_upload_replaces_the_existing_single_template
    WbsExcelTemplate.replace!(file_name: "old.xlsm", content: "dummy", uploaded_by_user: @admin)

    post "/api/v1/backlog_activities/wbs_excel_template",
         params: { file: uploaded_template_file },
         headers: auth_headers(@admin)

    assert_response :success
    assert_equal 1, WbsExcelTemplate.count
    assert_equal "wbs_schedule_template.xlsm", WbsExcelTemplate.current.file_name
  end

  def test_export_returns_generated_xlsm_with_wbs_headers
    WbsExcelTemplate.replace!(
      file_name: "wbs_schedule_template.xlsm",
      content: File.binread(TEMPLATE_PATH),
      uploaded_by_user: @admin
    )
    @notion_tasks << NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: "1.1", title: "更新後タスクA",
      assignee_name: "担当A2", workload: 2.5, progress_rate: 0.8,
      start_date: Date.new(2026, 9, 2), end_date: Date.new(2026, 9, 12), synced_at: Time.current
    )

    travel_to Time.zone.local(2026, 9, 8) do
      get "/api/v1/backlog_activities/wbs_excel_export", headers: auth_headers(@admin)
    end

    assert_response :success
    assert_equal "application/vnd.ms-excel.sheet.macroEnabled.12", response.media_type
    expected_filename = ERB::Util.url_encode("進捗報告書_20260908.xlsm")
    assert_match(/filename\*=UTF-8''#{expected_filename}/, response.headers["Content-Disposition"])
    assert_equal "1", response.headers["X-Wbs-Matched"]
    assert_equal "0", response.headers["X-Wbs-Appended"]
    assert_equal "0", response.headers["X-Wbs-Skipped"]
  end

  def test_mark_submitted_snapshots_unsubmitted_overrides_and_returns_count
    task_with_override = NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: "1.1", title: "元タイトル",
      assignee_name: "担当A", start_date_prev: Date.new(2026, 9, 20),
      synced_at: Time.current
    )
    task_without_override = NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: "1.2", title: "元タイトルB",
      assignee_name: "担当B", synced_at: Time.current
    )
    @notion_tasks << task_with_override << task_without_override

    post "/api/v1/backlog_activities/wbs_mark_submitted", headers: auth_headers(@admin)

    assert_response :success
    assert_equal 1, response.parsed_body["submitted_tasks"]
    refute task_with_override.reload.unsubmitted_override?(:start_date)
    refute task_without_override.reload.unsubmitted_override?(:title)
  end

  def test_import_applies_differing_cells_and_returns_counts
    @notion_tasks << NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: "1.1", title: "元タイトル", assignee_name: "担当A",
      progress_rate: 0.5, workload: 2, start_date: Date.new(2026, 9, 5), end_date: Date.new(2026, 9, 10),
      synced_at: Time.current
    )

    post "/api/v1/backlog_activities/wbs_excel_import",
         params: { file: uploaded_template_file },
         headers: auth_headers(@admin)

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["applied_task_count"]
    assert_equal 1, body["applied_cell_count"] # start_date がシート(2026-09-01)とタスクの元の値(2026-09-05)で異なる
    assert_equal 0, body["cleared_cell_count"]
    assert_equal 2, body["unmatched_row_count"] # 1.2, 2.1.1 に対応するタスクが無い
    assert_equal 0, body["unchanged_row_count"]
  end

  # notion_task_options(index の notion_tasks)に、登録済みテンプレの該当WBS行の値が入る
  def test_index_includes_wbs_template_values_for_matching_task
    WbsExcelTemplate.replace!(
      file_name: "wbs_schedule_template.xlsm",
      content: File.binread(TEMPLATE_PATH),
      uploaded_by_user: @admin
    )
    @notion_tasks << NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: "1.1", title: "タイトル", assignee_name: "担当A",
      synced_at: Time.current
    )

    get "/api/v1/backlog_activities", params: { user_id: @admin.id }, headers: auth_headers(@admin)

    assert_response :success
    notion_task = response.parsed_body["notion_tasks"].find { |task| task["wbs_level"] == "1.1" }
    assert_equal(
      { "progress_rate" => 0.5, "workload" => 2.0, "start_date" => "2026-09-01", "end_date" => "2026-09-10" },
      notion_task["wbs_template_values"]
    )
  end

  # テンプレ未登録なら wbs_template_values は nil
  def test_index_wbs_template_values_is_nil_when_template_is_not_registered
    @notion_tasks << NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: "1.1", title: "タイトル", assignee_name: "担当A",
      synced_at: Time.current
    )

    get "/api/v1/backlog_activities", params: { user_id: @admin.id }, headers: auth_headers(@admin)

    assert_response :success
    notion_task = response.parsed_body["notion_tasks"].find { |task| task["wbs_level"] == "1.1" }
    assert_nil notion_task["wbs_template_values"]
  end

  def test_import_rejects_unsupported_extension
    Tempfile.create([ "wbs_report", ".txt" ]) do |file|
      File.binwrite(file.path, File.binread(TEMPLATE_PATH))
      post "/api/v1/backlog_activities/wbs_excel_import",
           params: { file: Rack::Test::UploadedFile.new(file.path, "text/plain") },
           headers: auth_headers(@admin)
    end

    assert_response :unprocessable_entity
    assert_match(/xlsx|xlsm/, response.parsed_body["error"])
  end

  private

  def uploaded_template_file
    Rack::Test::UploadedFile.new(TEMPLATE_PATH, "application/vnd.ms-excel.sheet.macroEnabled.12")
  end

  # workbook.xml に「プロジェクトのスケジュール」シートが存在しない最小限の zip を組み立てる
  def build_zip_without_schedule_sheet
    buffer = Zip::OutputStream.write_buffer do |zip_output|
      zip_output.put_next_entry("[Content_Types].xml")
      zip_output.write("<Types/>")
      zip_output.put_next_entry("xl/workbook.xml")
      zip_output.write('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets><sheet name="別シート" r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></sheets></workbook>')
    end
    buffer.string
  end
end
