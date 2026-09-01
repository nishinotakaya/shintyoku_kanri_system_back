require "test_helper"

# 請求書ごとの宛先(請求先マスタの選択)。
# 選んだ時点の宛名・敬称を請求書にスナップショットするので、
# 後からマスタを直しても既存の請求書の宛先は変わらない。
class Api::V1::InvoiceClientSelectionTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "ics_user_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "西野 雄太郎",
                         closing_day: 31, work_categories: [ "transport" ])
    @client = @user.invoice_clients.create!(name: "株式会社ハウクル物流", honorific: "御中")
    @submission = InvoiceSubmission.create!(user: @user, year: 2026, month: 9,
                                            category: "transport", kind: "invoice", status: "draft")
  end

  def teardown
    @submission&.destroy
    @user&.destroy
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_selecting_a_client_snapshots_the_addressee
    patch "/api/v1/invoice_submissions/#{@submission.id}", params: { invoice_client_id: @client.id },
          headers: auth_headers(@user), as: :json

    assert_response :success
    @submission.reload

    assert_equal @client.id, @submission.invoice_client_id
    assert_equal "株式会社ハウクル物流", @submission.client_name_override
    assert_equal "御中", @submission.client_honorific_override
  end

  # マスタの名前を直しても、既に選んだ請求書の宛先は動かない(発行済みの整合性を守る)
  def test_editing_the_master_does_not_change_existing_invoices
    @submission.update!(invoice_client_id: @client.id, client_name_override: @client.name,
                        client_honorific_override: "御中")

    patch "/api/v1/invoice_clients/#{@client.id}", params: { invoice_client: { name: "株式会社ハウクル物流(新)" } },
          headers: auth_headers(@user), as: :json

    assert_response :success
    assert_equal "株式会社ハウクル物流", @submission.reload.client_name_override
  end

  def test_clearing_the_client_falls_back_to_the_setting
    @submission.update!(invoice_client_id: @client.id, client_name_override: @client.name)

    patch "/api/v1/invoice_submissions/#{@submission.id}", params: { invoice_client_id: "" },
          headers: auth_headers(@user), as: :json

    assert_response :success
    @submission.reload

    assert_nil @submission.invoice_client_id
    assert_nil @submission.client_name_override
  end

  # 他人の請求先 ID を渡しても、その宛先は焼き付かない
  def test_cannot_use_another_users_client
    stranger = User.create!(email: "ics_stranger_#{SecureRandom.hex(4)}@example.com",
                            password: "password123", display_name: "他人 花子", closing_day: 25)
    stranger_client = stranger.invoice_clients.create!(name: "他人の取引先")

    patch "/api/v1/invoice_submissions/#{@submission.id}", params: { invoice_client_id: stranger_client.id },
          headers: auth_headers(@user), as: :json

    assert_response :success
    assert_nil @submission.reload.client_name_override
  ensure
    stranger&.destroy
  end

  # 請求書は焼き付けた宛先(敬称つき)で描画され、設定の古い宛先は出ない
  def test_renderer_uses_the_snapshotted_addressee
    setting = @user.invoice_setting_for("transport")
    setting.update!(client_name: "設定に残った古い宛先", honorific: "御中", issuer_name: "西野 雄太郎")

    html = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport",
                                  client_name_override: "株式会社ハウクル物流",
                                  honorific_override: "御中").build_html

    assert_includes html, "株式会社ハウクル物流"
    assert_not_includes html, "設定に残った古い宛先"
  end

  # 宛先を指定しなければ、従来どおり請求書設定の client_name が使われる(既存ユーザーの挙動維持)
  def test_renderer_falls_back_to_the_setting_when_no_client_is_given
    setting = @user.invoice_setting_for("transport")
    setting.update!(client_name: "HAUKUR運送", honorific: "御中", issuer_name: "西野 雄太郎")

    html = InvoicePdfRenderer.new(@user, year: 2026, month: 9, category: "transport").build_html

    assert_includes html, "HAUKUR運送"
  end
end
