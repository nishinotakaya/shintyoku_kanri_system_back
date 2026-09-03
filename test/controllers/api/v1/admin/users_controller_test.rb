require "test_helper"

# Api::V1::Admin::UsersController: admin は全ユーザー、サブ管理者(テナント代表)は自分の管理対象だけを
# 一覧・作成・更新できる。例: 西野 雄太郎(HAUKUR運送代表) → 外注ドライバー。
#
# 注意: このアプリのテストはトランザクションでロールバックされないため、
# email はランダムサフィックスで一意にし、teardown で必ず destroy する。
class Api::V1::Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  def setup
    suffix = SecureRandom.hex(4)
    @admin = User.create!(email: "users_admin_#{suffix}@example.com", password: "password123",
                          display_name: "西野 鷹也", closing_day: 25)
    @owner = User.create!(email: "users_owner_#{suffix}@example.com", password: "password123",
                          display_name: "西野 雄太郎", closing_day: 31,
                          work_categories: [ "transport" ], feature_flags: { "skill_sheet" => true })
    @driver = User.create!(email: "users_driver_#{suffix}@example.com", password: "password123",
                           display_name: "運送外注 太郎", closing_day: 31)
    @stranger = User.create!(email: "users_stranger_#{suffix}@example.com", password: "password123",
                             display_name: "他人 花子", closing_day: 25)
    @tenant = Tenant.create!(name: "テスト運送_#{suffix}", code: "t-#{suffix}", owner_user: @owner)
    @tenant.tenant_memberships.create!(user: @driver)
    @created = nil
  end

  def teardown
    @tenant&.destroy
    [ @created, @admin, @owner, @driver, @stranger ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_tenant_owner_lists_only_own_members_and_self
    get "/api/v1/admin/users", headers: auth_headers(@owner)

    assert_response :success
    ids = response.parsed_body["users"].map { |u| u["id"] }
    assert_equal [ @owner.id, @driver.id ].sort, ids.sort
    assert_equal [], response.parsed_body["calendar_person_candidates"]
  end

  def test_admin_lists_everyone
    get "/api/v1/admin/users", headers: auth_headers(@admin)

    assert_response :success
    ids = response.parsed_body["users"].map { |u| u["id"] }
    assert_includes ids, @stranger.id
    assert_includes ids, @driver.id
    # カレンダー候補にはテナント(会社)に紐づく人物行も出る(候補に無いとチェックを外せない)
    candidates = response.parsed_body["calendar_person_candidates"]
    assert_includes candidates, "西野 雄太郎"
    assert_includes candidates, "運送外注"
  end

  def test_plain_user_is_forbidden
    get "/api/v1/admin/users", headers: auth_headers(@stranger)

    assert_response :forbidden
  end

  # admin 列は存在しない(氏名・メール一致で判定)ので、admin: true を送っても無視される
  def test_tenant_owner_creates_a_member_who_inherits_defaults_and_is_never_admin
    email = "users_new_#{SecureRandom.hex(4)}@example.com"
    post "/api/v1/admin/users",
         params: { email: email, display_name: "新人 ドライバー", admin: true, send_invite: false },
         headers: auth_headers(@owner), as: :json

    assert_response :created
    @created = User.find(response.parsed_body["id"])
    refute @created.admin?
    assert_equal [ "transport" ], @created.work_categories
    assert_equal 31, @created.closing_day
    assert_equal({ "skill_sheet" => true }, @created.feature_flags.to_h)
    assert_includes @owner.managees.reload, @created
    assert_includes @tenant.member_users.reload, @created
    assert @owner.can_manage_user?(@created.id)
  end

  def test_tenant_owner_cannot_update_a_stranger
    patch "/api/v1/admin/users/#{@stranger.id}", params: { feature_flags: { skill_sheet: true } },
          headers: auth_headers(@owner), as: :json

    assert_response :forbidden
    refute @stranger.reload.can_use?(:skill_sheet)
  end

  def test_tenant_owner_cannot_touch_admin_only_keys
    patch "/api/v1/admin/users/#{@driver.id}", params: { managee_ids: [ @stranger.id ] },
          headers: auth_headers(@owner), as: :json

    assert_response :forbidden
    assert_empty @driver.managees.reload
  end

  def test_tenant_owner_grants_only_features_they_can_use_themselves
    patch "/api/v1/admin/users/#{@driver.id}",
          params: { feature_flags: { skill_sheet: true, youtube_mindmap: true } },
          headers: auth_headers(@owner), as: :json

    assert_response :success
    flags = @driver.reload.feature_flags.to_h
    assert_equal true, flags["skill_sheet"]
    refute flags.key?("youtube_mindmap")
  end

  def test_tenant_owner_cannot_expose_categories_they_do_not_see
    patch "/api/v1/admin/users/#{@driver.id}", params: { work_categories: [ "wings" ] },
          headers: auth_headers(@owner), as: :json

    assert_response :forbidden
    assert_nil @driver.reload.work_categories
  end

  def test_admin_can_still_assign_managees
    patch "/api/v1/admin/users/#{@owner.id}", params: { managee_ids: [ @stranger.id ] },
          headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_equal [ @stranger.id ], @owner.managees.reload.map(&:id)
  end
  # GmailSender をスタブして外部送信しない(送信内容は配列で受け取る)
  def with_gmail_stub(error: nil)
    sent_mails = []
    original_send = GmailSender.instance_method(:send_mail)
    GmailSender.define_method(:send_mail) do |to:, subject:, body:, attachments: [], from_name: nil, bcc: nil|
      raise error if error
      sent_mails << { to: to, subject: subject, body: body, from_name: from_name }
      "stub-message-id"
    end
    yield sent_mails
  ensure
    GmailSender.define_method(:send_mail, original_send)
  end

  def test_sub_admin_can_resend_invite_to_their_member
    @owner.update!(google_access_token: "dummy-token")
    sent_mails = nil
    with_gmail_stub do |mails|
      sent_mails = mails
      post "/api/v1/admin/users/#{@driver.id}/invite", headers: auth_headers(@owner), as: :json
    end

    assert_response :success
    assert_equal true, response.parsed_body["invite_sent"]
    assert_equal 1, sent_mails.size
    assert_equal @driver.email, sent_mails.first[:to]
    assert_includes sent_mails.first[:body], "/sign_in"
    assert_equal @owner.display_name, sent_mails.first[:from_name]
  end

  def test_sub_admin_cannot_invite_users_outside_their_scope
    @owner.update!(google_access_token: "dummy-token")
    with_gmail_stub do
      post "/api/v1/admin/users/#{@stranger.id}/invite", headers: auth_headers(@owner), as: :json
    end

    assert_response :forbidden
  end

  def test_admin_can_resend_invite_to_anyone
    @admin.update!(google_access_token: "dummy-token")
    with_gmail_stub do |mails|
      post "/api/v1/admin/users/#{@stranger.id}/invite", headers: auth_headers(@admin), as: :json
      assert_equal [ @stranger.email ], mails.map { |m| m[:to] }
    end

    assert_response :success
  end

  def test_invite_failure_returns_bad_gateway
    @admin.update!(google_access_token: "dummy-token")
    with_gmail_stub(error: RuntimeError.new("gmail down")) do
      post "/api/v1/admin/users/#{@stranger.id}/invite", headers: auth_headers(@admin), as: :json
    end

    assert_response :bad_gateway
    assert_equal false, response.parsed_body["invite_sent"]
  end
end
