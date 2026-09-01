require "test_helper"

# 請求先(宛先)マスタ: 自分の請求先だけを CRUD できる。削除はアーカイブ(過去の請求書が参照するため)。
#
# 注意: このアプリのテストはトランザクションでロールバックされないため、
# email はランダムサフィックスで一意にし、teardown で必ず destroy する。
class Api::V1::InvoiceClientsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = User.create!(email: "ic_owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 雄太郎", closing_day: 31)
    @other = User.create!(email: "ic_other_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "運送外注 太郎", closing_day: 31)
  end

  def teardown
    [ @owner, @other ].compact.each(&:destroy)
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_create_and_list_own_clients
    post "/api/v1/invoice_clients",
         params: { invoice_client: { name: "株式会社ハウクル物流", honorific: "御中", is_default: true } },
         headers: auth_headers(@owner), as: :json

    assert_response :created
    assert_equal "株式会社ハウクル物流", JSON.parse(response.body)["name"]

    get "/api/v1/invoice_clients", headers: auth_headers(@owner)

    assert_response :success
    assert_equal [ "株式会社ハウクル物流" ], JSON.parse(response.body).map { |client| client["name"] }
  end

  def test_other_users_clients_are_not_listed
    @owner.invoice_clients.create!(name: "取引先A")

    get "/api/v1/invoice_clients", headers: auth_headers(@other)

    assert_response :success
    assert_empty JSON.parse(response.body)
  end

  def test_cannot_update_another_users_client
    client = @owner.invoice_clients.create!(name: "取引先A")

    patch "/api/v1/invoice_clients/#{client.id}", params: { invoice_client: { name: "乗っ取り" } },
          headers: auth_headers(@other), as: :json

    assert_response :not_found
    assert_equal "取引先A", client.reload.name
  end

  def test_destroy_archives_instead_of_deleting
    client = @owner.invoice_clients.create!(name: "取引先A")

    delete "/api/v1/invoice_clients/#{client.id}", headers: auth_headers(@owner)

    assert_response :no_content
    assert_not_nil client.reload.archived_at
    assert_empty @owner.invoice_clients.active
  end

  # 既定はユーザーごとに1件。新しく既定を立てたら前の既定は外れる。
  def test_only_one_default_per_user
    first = @owner.invoice_clients.create!(name: "取引先A", is_default: true)
    second = @owner.invoice_clients.create!(name: "取引先B", is_default: true)

    assert_not first.reload.is_default
    assert second.reload.is_default
    assert_equal second.id, @owner.default_invoice_client.id
  end
end
