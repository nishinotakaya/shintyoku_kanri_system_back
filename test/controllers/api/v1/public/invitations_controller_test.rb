require "test_helper"

# 招待リンク(/invite/:token → public/invitations): show で招待情報を返し、
# accept でパスワード設定+JWT発行。使用済み・無効トークンは弾く。
class Api::V1::Public::InvitationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @invitee = User.create!(email: "invitee_#{SecureRandom.hex(4)}@example.com",
                            password: Devise.friendly_token[0, 24],
                            display_name: "招待 花子", closing_day: 25)
    @token = @invitee.signed_id(purpose: :invitation, expires_in: 14.days)
  end

  def teardown
    @invitee&.destroy
  end

  def with_gmail_stub
    sent_mails = []
    original_send = GmailSender.instance_method(:send_mail)
    GmailSender.define_method(:send_mail) do |to:, subject:, body:, attachments: [], from_name: nil, bcc: nil|
      sent_mails << { to: to, subject: subject, body: body }
      "stub-message-id"
    end
    yield sent_mails
  ensure
    GmailSender.define_method(:send_mail, original_send)
  end

  def test_show_returns_invitation_info
    get "/api/v1/public/invitations/#{@token}"

    assert_response :success
    body = response.parsed_body
    assert_equal @invitee.email, body["email"]
    assert_equal "招待 花子", body["display_name"]
    assert_equal false, body["accepted"]
  end

  def test_show_rejects_invalid_token
    get "/api/v1/public/invitations/not-a-valid-token"

    assert_response :not_found
  end

  def test_show_rejects_token_with_wrong_purpose
    other_token = @invitee.signed_id(purpose: :password_reset, expires_in: 14.days)

    get "/api/v1/public/invitations/#{other_token}"

    assert_response :not_found
  end

  def test_accept_sets_password_and_returns_jwt_and_sends_confirmation
    @invitee.update!(google_access_token: "dummy-token")
    sent_mails = nil
    with_gmail_stub do |mails|
      sent_mails = mails
      post "/api/v1/public/invitations/#{@token}/accept",
           params: { password: "newpassword123", display_name: "招待 花子(本名)" }, as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert body["token"].present?, "JWT が返ること"
    assert_equal "招待 花子(本名)", body.dig("user", "display_name")
    @invitee.reload
    assert @invitee.invitation_accepted_at.present?
    assert @invitee.valid_password?("newpassword123")
    # 確認メールが本人に届く
    assert_equal 1, sent_mails.size
    assert_equal @invitee.email, sent_mails.first[:to]
    assert_includes sent_mails.first[:subject], "登録が完了しました"
    # 返ってきた JWT でそのままログインできる
    get "/api/v1/me", headers: { "Authorization" => "Bearer #{body['token']}" }
    assert_response :success
  end

  def test_accept_rejects_reused_invitation
    @invitee.update!(invitation_accepted_at: Time.current)

    post "/api/v1/public/invitations/#{@token}/accept", params: { password: "newpassword123" }, as: :json

    assert_response :conflict
    assert_includes response.parsed_body["error"], "既に使用されています"
  end

  def test_accept_rejects_short_password
    with_gmail_stub do |_mails|
      post "/api/v1/public/invitations/#{@token}/accept", params: { password: "abc" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_nil @invitee.reload.invitation_accepted_at
  end

  def test_accept_succeeds_even_if_confirmation_mail_fails
    original_send = GmailSender.instance_method(:send_mail)
    GmailSender.define_method(:send_mail) { |**| raise "SMTP down" }
    begin
      post "/api/v1/public/invitations/#{@token}/accept", params: { password: "newpassword123" }, as: :json
    ensure
      GmailSender.define_method(:send_mail, original_send)
    end

    assert_response :success
    assert @invitee.reload.invitation_accepted_at.present?
  end
end
