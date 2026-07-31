require "test_helper"

# GET /api/v1/exports/my_documents の doc_types パース（カンマ区切り）と本人限定スコープ。
class ExportsMyDocumentsTest < ActionDispatch::IntegrationTest
  def setup
    @owner = User.create!(email: "owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "川村 卓也", closing_day: 25)
    [ @owner, @other ].each do |user|
      InvoiceSubmission.create!(user: user, year: 2026, month: 7, category: "wings",
                                kind: "invoice", status: "approved", total_override: 100_000)
      InvoiceSubmission.create!(user: user, year: 2026, month: 7, category: "wings",
                                kind: "expense", status: "approved", total_override: 5_000)
    end
  end

  def teardown
    [ @owner, @other ].compact.each do |user|
      InvoiceSubmission.where(user_id: user.id).delete_all
      InvoiceSetting.where(user_id: user.id).delete_all
      user.destroy
    end
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def test_returns_only_own_documents
    get "/api/v1/exports/my_documents", headers: auth_headers(@owner)

    assert_response :success
    documents = JSON.parse(response.body)
    assert documents.any?
    assert_empty documents.select { |doc| doc["filename"].to_s.include?("川村") },
      "他ユーザーの帳票が返ってはいけない"
  end

  def test_doc_types_is_comma_separated
    get "/api/v1/exports/my_documents", params: { doc_types: "expense" }, headers: auth_headers(@owner)

    assert_response :success
    documents = JSON.parse(response.body)
    assert documents.any?
    assert_equal [ "expense" ], documents.map { |doc| doc["doc_type"] }.uniq
  end

  def test_requires_authentication
    get "/api/v1/exports/my_documents"
    assert_response :unauthorized
  end
end
