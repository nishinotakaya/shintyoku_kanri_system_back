require "test_helper"

# サブ管理者(テナント代表)への請求書機能開放と、下書きでも PDF と同じ既定値を返す件のテスト。
# - 下書き(draft)でも default_total / default_items / (運送は)立替金の既定値が返る
# - サブ管理者は管理対象ユーザーの申請を閲覧・承認できる
# - サブ管理者の自分宛申請は自動承認（自分がテナント代表=承認者のため）
# - 統合PDF(merged_invoice)・一括メール下書き(labop_draft)がサブ管理者に開放され、管理対象外は拒否
class Api::V1::InvoiceSubmissionBulkFeaturesTest < ActionDispatch::IntegrationTest
  def setup
    suffix = SecureRandom.hex(4)
    @owner = User.create!(email: "bulk_owner_#{suffix}@example.com", password: "password123",
                          display_name: "西野 雄太郎", closing_day: 31, work_categories: [ "transport" ])
    @driver = User.create!(email: "bulk_driver_#{suffix}@example.com", password: "password123",
                           display_name: "運送外注 太郎", closing_day: 31, work_categories: [ "transport" ])
    @stranger = User.create!(email: "bulk_stranger_#{suffix}@example.com", password: "password123",
                             display_name: "他人 花子", closing_day: 25)
    @tenant = Tenant.create!(name: "テスト運送_#{suffix}", code: "bk-#{suffix}", owner_user: @owner)
    @tenant.tenant_memberships.create!(user: @driver)
    @client = @owner.invoice_clients.create!(name: "株式会社ハウクル物流", honorific: "御中", is_default: true)

    setting = @owner.invoice_setting_for("transport")
    setting.update!(unit_price: 2_000)
    @owner.work_reports.create!(work_date: Date.new(2026, 9, 1), hours: 5, category: "transport")
    @owner.expenses.create!(expense_date: Date.new(2026, 9, 1), purpose: "高速代", amount: 3_000,
                            category: "transport", company_burden: true)
  end

  def teardown
    users = [ @owner, @driver, @stranger ].compact
    InvoiceSubmission.where(user: users).destroy_all
    @tenant&.destroy
    users.each do |user|
      user.work_reports.destroy_all
      user.expenses.destroy_all
      user.invoice_clients.destroy_all
      user.invoice_settings.destroy_all
      user.destroy
    end
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def create_submission(user, status: "draft", kind: "invoice")
    InvoiceSubmission.create!(user: user, year: 2026, month: 9, category: "transport",
                              kind: kind, status: status)
  end

  # PDF 生成(node/puppeteer)はテストでは走らせない
  def with_invoice_pdf_stub
    original = InvoicePdfRenderer.instance_method(:call)
    InvoicePdfRenderer.define_method(:call) do
      path = Rails.root.join("tmp/exports/stub_#{SecureRandom.hex(4)}.pdf").to_s
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "%PDF-1.4 stub")
      path
    end
    yield
  ensure
    InvoicePdfRenderer.define_method(:call, original)
  end

  # 下書きでも PDF と同じ金額・明細・(運送は)立替金の既定値が返る（「編集だと金額が空」対策）
  def test_draft_invoice_returns_pdf_matching_defaults
    create_submission(@owner)

    get "/api/v1/invoice_submissions", params: { status: "all", kind: "invoice" },
        headers: auth_headers(@owner)

    assert_response :success
    row = response.parsed_body.find { |r| r["user_id"] == @owner.id }
    assert row, "自分の下書きが一覧に出ること"
    assert_operator row["default_total"].to_i, :>, 0, "下書きでも default_total が入ること"
    assert row["default_items"].is_a?(Array) && row["default_items"].any?, "下書きでも default_items が入ること"
    assert_equal 3_000, row["default_transport_expense_total"], "運送は立替金合計も返ること"
    assert_equal "高速代", row["default_transport_expenses"].first["label"]
  end

  def test_sub_admin_sees_and_approves_member_submissions
    submission = create_submission(@driver, status: "pending")

    get "/api/v1/invoice_submissions", params: { status: "all" }, headers: auth_headers(@owner)
    assert_response :success
    assert_includes response.parsed_body.map { |r| r["id"] }, submission.id, "サブ管理者はメンバーの申請が見えること"

    patch "/api/v1/invoice_submissions/#{submission.id}", params: { status: "approved" },
          headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal "approved", submission.reload.status

    other = create_submission(@stranger, status: "pending")
    patch "/api/v1/invoice_submissions/#{other.id}", params: { status: "approved" },
          headers: auth_headers(@owner), as: :json
    assert_response :forbidden, "管理対象外の申請は承認できないこと"
  end

  def test_sub_admin_own_submit_auto_approves
    submission = create_submission(@owner)

    post "/api/v1/invoice_submissions/#{submission.id}/submit", headers: auth_headers(@owner)

    assert_response :success
    assert_equal "approved", submission.reload.status, "テナント代表の自分宛申請は自動承認されること"
  end

  def test_sub_admin_merges_own_and_member_invoices
    own = create_submission(@owner, status: "approved")
    member = create_submission(@driver, status: "approved")

    with_invoice_pdf_stub do
      post "/api/v1/exports/merged_invoice.pdf",
           params: { "invoice_submission_ids[]" => [ own.id, member.id ] },
           headers: auth_headers(@owner)
    end

    assert_response :success
    assert_equal "application/pdf", response.media_type
  end

  def test_merge_rejects_non_admin_and_unmanageable_targets
    own = create_submission(@owner, status: "approved")
    outside = create_submission(@stranger, status: "approved")

    post "/api/v1/exports/merged_invoice.pdf",
         params: { "invoice_submission_ids[]" => [ own.id ] },
         headers: auth_headers(@stranger)
    assert_response :forbidden, "一般ユーザーは統合できないこと"

    post "/api/v1/exports/merged_invoice.pdf",
         params: { "invoice_submission_ids[]" => [ own.id, outside.id ] },
         headers: auth_headers(@owner)
    assert_response :forbidden, "管理対象外の申請が混ざったら統合できないこと"
  end

  # 一括メール下書き: サブ管理者に開放され、宛名は既定請求先から入る
  def test_sub_admin_bulk_mail_draft_uses_default_client
    own = create_submission(@owner, status: "approved")

    post "/api/v1/emails/labop_draft",
         params: { invoice_submission_ids: [ own.id ] },
         headers: auth_headers(@owner), as: :json

    assert_response :success
    assert_equal "株式会社ハウクル物流 御中", response.parsed_body["recipient_name"]
  end
end
