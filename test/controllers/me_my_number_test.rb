require "test_helper"

# /me の個人番号(my_number)・生年月日(birth_date): admin(本人)だけが登録でき、
# レスポンスには末尾4桁しか出ない。他ユーザーの個人番号をサーバに保管しない方針の回帰ガード。
class MeMyNumberTest < ActionDispatch::IntegrationTest
  VALID_NUMBER = "123456789018".freeze

  def setup
    @admin = User.create!(email: User::ADMIN_EMAILS.first, password: "password123", display_name: "西野 鷹也")
    @member = User.create!(email: "member_#{SecureRandom.hex(4)}@example.com", password: "password123", display_name: "一般ユーザー")
  end

  def teardown
    @admin&.destroy
    @member&.destroy
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_admin_can_save_my_number_and_birth_date_and_gets_only_last4_back
    patch "/api/v1/me", params: { user: { my_number: "1234-5678-9018", birth_date: "1990-09-30" } },
          headers: auth_headers(@admin), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["my_number_registered"]
    assert_equal "9018", body["my_number_last4"]
    assert_equal "1990-09-30", body["birth_date"]
    refute_includes response.body, VALID_NUMBER, "個人番号そのものを返してはいけない"
    assert_equal VALID_NUMBER, @admin.reload.my_number
  end

  def test_admin_can_clear_with_blank_values
    @admin.update!(my_number: VALID_NUMBER, birth_date: Date.new(1990, 9, 30))

    patch "/api/v1/me", params: { user: { my_number: "", birth_date: "" } }, headers: auth_headers(@admin), as: :json

    assert_response :success
    assert_nil @admin.reload.my_number
    assert_nil @admin.birth_date
    assert_equal false, response.parsed_body["my_number_registered"]
  end

  def test_wrong_check_digit_is_rejected
    patch "/api/v1/me", params: { user: { my_number: "123456789019" } }, headers: auth_headers(@admin), as: :json

    assert_response :unprocessable_entity
    assert_nil @admin.reload.my_number
  end

  def test_non_admin_cannot_save_my_number
    patch "/api/v1/me", params: { user: { my_number: VALID_NUMBER } }, headers: auth_headers(@member), as: :json

    assert_response :forbidden
    assert_nil @member.reload.my_number
  end

  def test_non_admin_cannot_use_card_reader
    post "/api/v1/me/my_number_card/read", headers: auth_headers(@member)

    assert_response :forbidden
  end

  def test_card_reader_requires_an_image
    post "/api/v1/me/my_number_card/read", headers: auth_headers(@admin)

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["error"], "画像"
  end

  def test_payload_does_not_expose_my_number_to_non_admin
    get "/api/v1/me", headers: auth_headers(@member)

    assert_response :success
    assert_equal false, response.parsed_body["my_number_registered"]
    assert_nil response.parsed_body["my_number_last4"]
  end
end
