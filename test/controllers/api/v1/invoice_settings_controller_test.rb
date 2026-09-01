require "test_helper"

# 請求書設定の読み書き先カテゴリ。
# category 未指定の既定は「そのユーザーが見える先頭のカテゴリ」で、work_categories を設定している
# ユーザー(運送専用など)には見えないカテゴリの設定を読ませない・作らせない。
# (以前は無条件に wings が既定だったため、運送ユーザーに Tama の既定明細(シェアラウンジ利用料)が混入し、
#  保存も wings 側に落ちて「設定を変えても計算が変わらない」状態になっていた)
#
# 注意: このアプリのテストはトランザクションでロールバックされないため、
# email はランダムサフィックスで一意にし、teardown で必ず destroy する。
class Api::V1::InvoiceSettingsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @transport_user = User.create!(email: "inv_transport_#{SecureRandom.hex(4)}@example.com",
                                   password: "password123", display_name: "運送 太郎",
                                   closing_day: 31, work_categories: [ "transport" ])
    @legacy_user = User.create!(email: "inv_legacy_#{SecureRandom.hex(4)}@example.com",
                                password: "password123", display_name: "従来 次郎", closing_day: 25)
  end

  def teardown
    [ @transport_user, @legacy_user ].compact.each do |user|
      user.invoice_settings.destroy_all
      user.destroy
    end
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_default_category_is_the_first_visible_one_for_transport_only_user
    get "/api/v1/invoice_setting", headers: auth_headers(@transport_user)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "transport", body["category"]
    assert_equal [], body["default_items"], "Tama の既定明細(シェアラウンジ利用料)が混入してはいけない"
  end

  def test_default_category_stays_wings_for_legacy_user_without_work_categories
    get "/api/v1/invoice_setting", headers: auth_headers(@legacy_user)

    assert_response :success
    assert_equal "wings", JSON.parse(response.body)["category"]
  end

  def test_transport_only_user_cannot_read_an_invisible_category
    get "/api/v1/invoice_setting", params: { category: "wings" }, headers: auth_headers(@transport_user)

    assert_response :unprocessable_entity
    assert_empty @transport_user.invoice_settings.where(category: "wings")
  end

  def test_update_saves_to_the_selected_category_even_if_loaded_setting_carried_another_category
    patch "/api/v1/invoice_setting",
          params: { invoice_setting: { category: "transport", pay_type: "daily", daily_rate: 17_000, overtime_unit_price: 2_000 },
                    category: "transport" },
          headers: auth_headers(@transport_user), as: :json

    assert_response :success
    saved = @transport_user.invoice_settings.find_by!(category: "transport")
    assert_equal "daily", saved.pay_type
    assert_equal 17_000, saved.daily_rate
    assert_equal 2_000, saved.overtime_unit_price
    assert_empty @transport_user.invoice_settings.where(category: "wings")
  end

  # 税込/税抜の切替は保存・返却される。既定は税抜(false)
  def test_tax_included_round_trips_and_defaults_to_false
    get "/api/v1/invoice_setting", headers: auth_headers(@transport_user)
    assert_equal false, JSON.parse(response.body)["tax_included"]

    patch "/api/v1/invoice_setting",
          params: { invoice_setting: { category: "transport", tax_included: true }, category: "transport" },
          headers: auth_headers(@transport_user), as: :json
    assert_response :success
    assert_equal true, JSON.parse(response.body)["tax_included"]
    assert @transport_user.invoice_settings.find_by!(category: "transport").tax_included?
  end

  def test_update_to_an_invisible_category_is_rejected_and_creates_nothing
    patch "/api/v1/invoice_setting",
          params: { invoice_setting: { category: "wings", pay_type: "daily", daily_rate: 17_000 }, category: "transport" },
          headers: auth_headers(@transport_user), as: :json

    assert_response :unprocessable_entity
    assert_empty @transport_user.invoice_settings
  end
end
