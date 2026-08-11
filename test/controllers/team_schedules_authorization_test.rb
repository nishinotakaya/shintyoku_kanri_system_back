require "test_helper"

# team_schedules の create/update は「admin か自分の苗字に一致する行」のみ。
# フロントの canEditPerson と同じ規則をサーバ側でも強制していることの回帰テスト。
class TeamSchedulesAuthorizationTest < ActionDispatch::IntegrationTest
  def setup
    # display_name に「西野」を含むと User#admin? が true になる(名前判定)
    @admin = User.create!(email: "admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @member = User.create!(email: "member_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "川村 卓也", closing_day: 25)
    @nishino_schedule = TeamSchedule.create!(date: Date.new(2026, 8, 3), person: "西野",
                                             status: "リモート", year_month: "202608")
  end

  def teardown
    TeamSchedule.where(year_month: "202608").delete_all
    [ @admin, @member ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_member_cannot_update_others_schedule
    patch "/api/v1/team_schedules/#{@nishino_schedule.id}", params: { status: "出社" },
          headers: auth_headers(@member), as: :json

    assert_response :forbidden
    assert_equal "リモート", @nishino_schedule.reload.status
  end

  def test_member_cannot_create_others_schedule
    post "/api/v1/team_schedules", params: { date: "2026-08-04", person: "西野", status: "休み" },
         headers: auth_headers(@member), as: :json

    assert_response :forbidden
    assert_nil TeamSchedule.find_by(date: Date.new(2026, 8, 4), person: "西野")
  end

  def test_member_can_create_own_schedule_with_notation_variants
    # シートヘッダ「川村卓也」× 自分の苗字「川村」の双方向マッチ
    post "/api/v1/team_schedules", params: { date: "2026-08-04", person: "川村卓也", status: "リモート" },
         headers: auth_headers(@member), as: :json

    assert_response :success
    assert TeamSchedule.exists?(date: Date.new(2026, 8, 4), person: "川村卓也")
  end

  def test_admin_can_update_anyones_schedule
    patch "/api/v1/team_schedules/#{@nishino_schedule.id}", params: { status: "休み" },
          headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_equal "休み", @nishino_schedule.reload.status
  end
end
