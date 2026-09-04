require "test_helper"
require "base64"

# Api::V1::Public::ContractsController: 乙(相手方)向けの公開エンドポイント。ログイン不要。
# 全レスポンスに Cache-Control: no-store / X-Robots-Tag: noindex,nofollow が付く。トークン不一致は404。
#
# PDFを実際に生成する(Node/Playwrightを起動する)テストは、
# 「署名の正常系(sign)」と「pdfアクション」の2本に絞る。二重署名・期限切れ・無効化後の
# 409は、update_columns で直接その状態を作って検証する(状態遷移ロジック自体は
# test/models/contract_test.rb 側で検証済み)。
class Api::V1::Public::ContractsControllerTest < ActionDispatch::IntegrationTest
  VALID_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=".freeze

  def setup
    @issuer = User.create!(email: "public_contracts_issuer_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "発行 太郎", closing_day: 25)
  end

  def teardown
    @issuer.destroy
  end

  # --- show ---

  def test_show_returns_contract_details_with_no_index_headers_and_records_viewed_event
    contract, raw_token = issue_contract(party_a_name: "西野商店", party_b_name: "取引先 太郎")

    get "/api/v1/public/contracts/#{raw_token}"

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]

    body = response.parsed_body
    assert_equal "西野商店", body["party_a"]["name"]
    assert_equal "取引先 太郎", body["party_b"]["name"]
    assert_equal "sent", body["status"]
    assert body["signable"]
    refute body["expired"]

    assert_equal "party_b", contract.contract_events.where(event: "viewed").last.actor
  end

  def test_show_returns_not_found_for_unknown_token
    get "/api/v1/public/contracts/this-token-does-not-exist"

    assert_response :not_found
    assert response.parsed_body["error"].present?
  end

  # --- sign ---

  # PDFを実際に生成する(Node/Playwrightを起動する)、いわゆる「sign正常系」のテスト。
  def test_sign_success_generates_signed_pdf_and_records_event
    contract, raw_token = issue_contract

    post "/api/v1/public/contracts/#{raw_token}/sign", params: valid_sign_params(signer_name: "取引先 花子"), as: :json

    assert_response :success
    assert_equal "signed", response.parsed_body["status"]
    assert response.parsed_body["signed_at"].present?

    contract.reload
    assert_equal "signed", contract.status
    assert_equal "取引先 花子", contract.signer_name
    assert_equal 64, contract.content_sha256.length
    assert_equal "%PDF", contract.signed_pdf.byteslice(0, 4)
    assert_equal "signed", contract.contract_events.order(:created_at).last.event
    assert_equal "party_b", contract.contract_events.order(:created_at).last.actor
  end

  def test_sign_returns_conflict_when_already_signed
    contract, raw_token = issue_contract
    contract.update_columns(status: "signed")

    post "/api/v1/public/contracts/#{raw_token}/sign", params: valid_sign_params, as: :json

    assert_response :conflict
    assert_equal "この契約書は署名できません（期限切れ・既に署名済み・無効）", response.parsed_body["error"]
  end

  def test_sign_returns_conflict_when_expired
    contract, raw_token = issue_contract
    contract.update_columns(share_expires_at: 1.minute.ago)

    post "/api/v1/public/contracts/#{raw_token}/sign", params: valid_sign_params, as: :json

    assert_response :conflict
  end

  def test_sign_returns_conflict_when_void
    contract, raw_token = issue_contract
    contract.update!(status: "void")

    post "/api/v1/public/contracts/#{raw_token}/sign", params: valid_sign_params, as: :json

    assert_response :conflict
  end

  def test_sign_returns_422_when_agreed_is_false
    _contract, raw_token = issue_contract

    post "/api/v1/public/contracts/#{raw_token}/sign",
         params: valid_sign_params(agreed: false, consent_electronic: true), as: :json

    assert_response :unprocessable_entity
  end

  def test_sign_returns_422_when_consent_electronic_is_false
    _contract, raw_token = issue_contract

    post "/api/v1/public/contracts/#{raw_token}/sign",
         params: valid_sign_params(agreed: true, consent_electronic: false), as: :json

    assert_response :unprocessable_entity
  end

  def test_sign_returns_422_for_non_png_image
    contract, raw_token = issue_contract

    post "/api/v1/public/contracts/#{raw_token}/sign",
         params: valid_sign_params(signature_image: "data:image/jpeg;base64,#{VALID_PNG_BASE64}"), as: :json

    assert_response :unprocessable_entity
    assert_equal "署名画像はPNG形式のみ対応しています", response.parsed_body["error"]
    contract.reload
    assert_equal "sent", contract.status
    assert_nil contract.signed_at
  end

  def test_sign_returns_422_for_oversized_image
    contract, raw_token = issue_contract
    oversized_binary = "\x89PNG\r\n\x1a\n".b + ("A" * (SignatureImage::MAX_BYTES + 1))

    post "/api/v1/public/contracts/#{raw_token}/sign",
         params: valid_sign_params(signature_image: "data:image/png;base64,#{Base64.strict_encode64(oversized_binary)}"),
         as: :json

    assert_response :unprocessable_entity
    assert_equal "署名画像は300KB以下にしてください", response.parsed_body["error"]
    assert_equal "sent", contract.reload.status
  end

  # --- pdf ---

  # PDFを実際に生成する(Node/Playwrightを起動する)、公開側pdfアクションのテスト。
  def test_pdf_action_returns_generated_pdf_for_sent_contract
    contract, raw_token = issue_contract

    get "/api/v1/public/contracts/#{raw_token}/pdf"

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_equal "%PDF", response.body.byteslice(0, 4)
    assert_equal "party_b", contract.contract_events.where(event: "pdf_viewed").last.actor
  end

  def test_pdf_action_returns_not_found_for_unknown_token
    get "/api/v1/public/contracts/this-token-does-not-exist/pdf"

    assert_response :not_found
  end

  def test_pdf_action_returns_stored_signed_pdf_for_signed_contract
    _contract, raw_token = issue_contract
    Contract.find_by_share_token(raw_token).update_columns(status: "signed", signed_pdf: "%PDF-stored-signed-blob".b)

    get "/api/v1/public/contracts/#{raw_token}/pdf"

    assert_response :success
    assert_equal "%PDF-stored-signed-blob", response.body
  end

  # --- 署名後の甲への通知(自動登録はせず、甲の「招待」操作で登録する) ---

  def with_sign_side_effect_stubs
    sent_mails = []
    original_send = GmailSender.instance_method(:send_mail)
    GmailSender.define_method(:send_mail) do |to:, subject:, body:, attachments: [], from_name: nil, bcc: nil|
      sent_mails << { to: to, subject: subject, body: body }
      "stub-message-id"
    end
    original_render = ContractPdfRenderer.instance_method(:render_bytes)
    ContractPdfRenderer.define_method(:render_bytes) { "%PDF-1.4 stub".b }
    yield sent_mails
  ensure
    GmailSender.define_method(:send_mail, original_send)
    ContractPdfRenderer.define_method(:render_bytes, original_render)
  end

  def test_sign_notifies_party_a_and_does_not_auto_register
    @issuer.update!(google_access_token: "dummy-token")
    partner_email = "party_b_#{SecureRandom.hex(4)}@example.com"
    contract, raw_token = issue_contract(party_b_name: "運送外注 太郎", party_b_email: partner_email)

    sent_mails = nil
    with_sign_side_effect_stubs do |mails|
      sent_mails = mails
      post "/api/v1/public/contracts/#{raw_token}/sign", params: valid_sign_params, as: :json
    end

    assert_response :success
    # 自動登録はしない(甲が「招待」を押すまで登録されない承認ゲート)
    assert_nil User.find_by(email: partner_email), "署名だけでは乙のユーザーは作られないこと"
    refute contract.contract_events.exists?(event: "party_b_registered")
    # 甲へ署名通知メールが飛ぶ
    assert_equal 1, sent_mails.size
    assert_equal @issuer.email, sent_mails.first[:to]
    assert_includes sent_mails.first[:subject], "署名しました"
    assert_includes sent_mails.first[:body], partner_email
    assert contract.contract_events.exists?(event: "party_a_notified")
  ensure
    User.find_by(email: partner_email)&.destroy
  end

  def test_sign_succeeds_even_if_notification_mail_fails
    contract, raw_token = issue_contract(party_b_email: "party_b_#{SecureRandom.hex(4)}@example.com")

    original_send = GmailSender.instance_method(:send_mail)
    GmailSender.define_method(:send_mail) { |**| raise "SMTP down" }
    original_render = ContractPdfRenderer.instance_method(:render_bytes)
    ContractPdfRenderer.define_method(:render_bytes) { "%PDF-1.4 stub".b }
    begin
      post "/api/v1/public/contracts/#{raw_token}/sign", params: valid_sign_params, as: :json
    ensure
      GmailSender.define_method(:send_mail, original_send)
      ContractPdfRenderer.define_method(:render_bytes, original_render)
    end

    assert_response :success
    assert_equal "signed", contract.reload.status
  end

  private

  def issue_contract(attrs = {})
    contract = @issuer.contracts.create!({ party_a_name: "甲社", party_b_name: "乙社" }.merge(attrs))
    raw_token = contract.issue!(actor: "user:#{@issuer.id}")
    [ contract, raw_token ]
  end

  def valid_sign_params(signer_name: "テスト 花子", signature_image: nil, agreed: true, consent_electronic: true)
    {
      signer_name: signer_name,
      signature_image: signature_image || "data:image/png;base64,#{VALID_PNG_BASE64}",
      agreed: agreed,
      consent_electronic: consent_electronic
    }
  end
end
