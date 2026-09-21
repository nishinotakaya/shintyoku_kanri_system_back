require "test_helper"

# UserProvisioning.send_invite!: テナントに冊子(操作手順書・トラブル別対応)が登録されていれば、
# 招待メールに全冊の PDF を添付し、本文にも冊子ごとの Web 版リンクを載せる。
class UserProvisioningInviteTest < ActiveSupport::TestCase
  def setup
    suffix = SecureRandom.hex(4)
    @owner = User.create!(email: "invite_owner_#{suffix}@example.com", password: "password123",
                          display_name: "西野 雄太郎", closing_day: 31, google_access_token: "dummy-token")
    @driver = User.create!(email: "invite_driver_#{suffix}@example.com", password: "password123",
                           display_name: "運送外注 太郎", closing_day: 31)
    @tenant = Tenant.create!(name: "HAUKUR運送", code: "haukur-#{suffix}", owner_user: @owner)
  end

  def teardown
    @tenant&.destroy
    [ @owner, @driver ].each(&:destroy)
  end

  def test_invite_mail_attaches_every_member_manual
    fetched_pdf_paths = []
    fake_fetch = ->(manual) {
      fetched_pdf_paths << manual[:pdf_path]
      { filename: manual[:pdf_filename], content_type: "application/pdf", body: "%PDF" }
    }

    sent_mail = with_manual_pdf_fetch(fake_fetch) do
      capture_sent_mail { UserProvisioning.send_invite!(invitee: @driver, inviter: @owner) }
    end

    assert_equal [ "/manuals/haukur_driver.pdf", "/manuals/haukur_trouble.pdf" ], fetched_pdf_paths
    assert_equal [ "操作手順書_ドライバー様向け.pdf", "トラブル別対応_ドライバー様向け.pdf" ],
                 sent_mail[:attachments].map { |attachment| attachment[:filename] }
    assert_includes sent_mail[:body], "▼ 操作手順書（ドライバー用）（このメールにPDFを添付しています）"
    assert_includes sent_mail[:body], "▼ トラブル別対応（このメールにPDFを添付しています）"
    assert_includes sent_mail[:body], "/manuals/haukur_driver.html"
    assert_includes sent_mail[:body], "/manuals/haukur_trouble.html"
  end

  def test_invite_mail_without_tenant_manuals_has_no_attachment
    @tenant.update!(name: "冊子なし運送")

    sent_mail = capture_sent_mail { UserProvisioning.send_invite!(invitee: @driver, inviter: @owner) }

    assert_equal [], sent_mail[:attachments]
    refute_includes sent_mail[:body], "PDFを添付"
  end

  private

  # 手順書PDFの HTTP 取得を差し替える(テストでは frontend に繋がない)
  def with_manual_pdf_fetch(fake_fetch)
    original_fetch = UserProvisioning.method(:fetch_manual_pdf)
    UserProvisioning.define_singleton_method(:fetch_manual_pdf) { |manual| fake_fetch.call(manual) }
    yield
  ensure
    UserProvisioning.define_singleton_method(:fetch_manual_pdf, original_fetch)
  end

  # GmailSender を差し替えて、実送信せずに送られたメール1通の内容を返す
  def capture_sent_mail
    original_send = GmailSender.instance_method(:send_mail)
    sent_mails = []
    GmailSender.define_method(:send_mail) do |to:, subject:, body:, attachments: [], from_name: nil, bcc: nil|
      sent_mails << { to: to, subject: subject, body: body, attachments: attachments, from_name: from_name }
      "stub-message-id"
    end
    yield
    assert_equal 1, sent_mails.size
    sent_mails.first
  ensure
    GmailSender.define_method(:send_mail, original_send)
  end
end
