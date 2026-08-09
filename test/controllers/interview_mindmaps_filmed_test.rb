require "test_helper"

# PATCH /api/v1/interview_mindmaps/:id の filmed(撮影済フラグ)更新と payload 反映。
class InterviewMindmapsFilmedTest < ActionDispatch::IntegrationTest
  def setup
    # display_name に「西野」を含むと User#admin? が true になる(名前判定)。youtube モードは admin 素通り
    @admin = User.create!(email: "admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @member = User.create!(email: "member_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "一般 太郎", closing_day: 25)
    @mindmap = InterviewMindmap.create!(user: @admin, mode: "youtube", title: "テスト動画タイトル")
  end

  def teardown
    @mindmap&.destroy
    [ @admin, @member ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_filmed_defaults_to_false_and_appears_in_payload
    get "/api/v1/interview_mindmaps/#{@mindmap.id}", headers: auth_headers(@admin)

    assert_response :success
    assert_equal false, JSON.parse(response.body)["filmed"]
  end

  def test_update_filmed_to_true_and_back
    patch "/api/v1/interview_mindmaps/#{@mindmap.id}", params: { filmed: true },
          headers: auth_headers(@admin), as: :json
    assert_response :success
    assert_equal true, JSON.parse(response.body)["filmed"]
    assert_equal true, @mindmap.reload.filmed

    patch "/api/v1/interview_mindmaps/#{@mindmap.id}", params: { filmed: false },
          headers: auth_headers(@admin), as: :json
    assert_response :success
    assert_equal false, @mindmap.reload.filmed
  end

  def test_update_without_filmed_keeps_flag
    @mindmap.update!(filmed: true)

    patch "/api/v1/interview_mindmaps/#{@mindmap.id}", params: { title: "改題した動画タイトル" },
          headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_equal true, @mindmap.reload.filmed, "filmed を送らない更新でフラグが落ちてはいけない"
  end

  def test_filmed_nil_is_ignored_not_error
    @mindmap.update!(filmed: true)

    patch "/api/v1/interview_mindmaps/#{@mindmap.id}", params: { filmed: nil },
          headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_equal true, @mindmap.reload.filmed, "filmed: null は無視され、NOT NULL 例外にならないこと"
  end

  def test_filmed_only_update_does_not_bump_updated_at
    original_updated_at = @mindmap.updated_at

    travel 1.minute do
      patch "/api/v1/interview_mindmaps/#{@mindmap.id}", params: { filmed: true },
            headers: auth_headers(@admin), as: :json
    end

    assert_response :success
    assert_equal original_updated_at.to_i, @mindmap.reload.updated_at.to_i,
      "撮影済フラグだけの更新で一覧の並び順(updated_at desc)が変わってはいけない"
  end

  def test_member_cannot_update_others_mindmap
    patch "/api/v1/interview_mindmaps/#{@mindmap.id}", params: { filmed: true },
          headers: auth_headers(@member), as: :json

    assert_response :forbidden
    assert_equal false, @mindmap.reload.filmed
  end
end
