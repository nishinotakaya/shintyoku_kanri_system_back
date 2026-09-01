require "test_helper"

# Api::V1::WorkReportsController: 検印(approve/unapprove)は所有者本人 or admin だけが押せる。
class Api::V1::WorkReportsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = User.create!(email: "work_reports_owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "運送 太郎", closing_day: 25)
    @stranger = User.create!(email: "work_reports_stranger_#{SecureRandom.hex(4)}@example.com",
                             password: "password123", display_name: "他人 花子", closing_day: 25)
    @admin = User.create!(email: "work_reports_admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @report = @owner.work_reports.create!(work_date: Date.current, category: "transport")
  end

  def teardown
    [ @owner, @stranger, @admin ].compact.each(&:destroy)
  end

  def test_owner_can_approve_own_report
    patch "/api/v1/work_reports/#{@report.id}/approve", headers: auth_headers(@owner)

    assert_response :success
    body = response.parsed_body
    assert body["approved"]
    assert_equal @owner.display_name, body["approved_by"]["display_name"]
  end

  def test_admin_can_approve_others_report
    patch "/api/v1/work_reports/#{@report.id}/approve", headers: auth_headers(@admin)

    assert_response :success
    assert response.parsed_body["approved"]
  end

  def test_stranger_cannot_approve_others_report
    patch "/api/v1/work_reports/#{@report.id}/approve", headers: auth_headers(@stranger)

    assert_response :forbidden
    refute @report.reload.approved?
  end

  def test_owner_can_unapprove_own_report
    @report.approve!(actor: @owner)

    delete "/api/v1/work_reports/#{@report.id}/approve", headers: auth_headers(@owner)

    assert_response :success
    refute response.parsed_body["approved"]
  end

  def test_stranger_cannot_unapprove_others_report
    @report.approve!(actor: @owner)

    delete "/api/v1/work_reports/#{@report.id}/approve", headers: auth_headers(@stranger)

    assert_response :forbidden
    assert @report.reload.approved?
  end

  private

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end
end
