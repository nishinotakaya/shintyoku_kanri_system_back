require "test_helper"

# 稼働報告書(運送)の実費レシート写真: expense_photos_add で複数保存 → serialize の expense_photos で
# メタデータを返し → expense_photo で画像取得 → remove_expense_photo_ids で削除。
# read_expense はAI読取(スタブ)で金額を返す。
class Api::V1::WorkReportExpensePhotosTest < ActionDispatch::IntegrationTest
  # 1x1 PNG
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAABAMAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze

  def setup
    @owner = User.create!(email: "expense_owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "運送 太郎", closing_day: 31)
  end

  def teardown
    @owner&.destroy
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def data_url
    "data:image/png;base64,#{Base64.strict_encode64(PNG_BYTES)}"
  end

  def test_create_with_expense_photos_persists_and_returns_metadata
    post "/api/v1/work_reports", headers: auth_headers(@owner), params: {
      work_date: Date.current.iso8601, category: "transport", transit_fee: 1800,
      expense_photos_add: [
        { data_base64: data_url, amount: 1200, label: "高速代(ETC)" },
        { data_base64: data_url, amount: 600, label: "駐車場代" }
      ]
    }, as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal 2, body["expense_photos"].size
    assert_equal [ 1200, 600 ], body["expense_photos"].map { |p| p["amount"] }
    assert_equal [ "高速代(ETC)", "駐車場代" ], body["expense_photos"].map { |p| p["label"] }
    report = @owner.work_reports.find(body["id"])
    assert_equal 2, report.expense_photos.count
    assert_equal PNG_BYTES, report.expense_photos.first.data
  end

  def test_update_can_remove_expense_photo
    report = @owner.work_reports.create!(work_date: Date.current, category: "transport")
    keep = report.expense_photos.create!(content_type: "image/png", data: PNG_BYTES, amount: 500, label: "駐車場代")
    remove = report.expense_photos.create!(content_type: "image/png", data: PNG_BYTES, amount: 300, label: "その他")

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      remove_expense_photo_ids: [ remove.id ]
    }, as: :json

    assert_response :success
    assert_equal [ keep.id ], report.reload.expense_photos.pluck(:id)
  end

  def test_expense_photo_returns_image_and_404_for_unknown
    report = @owner.work_reports.create!(work_date: Date.current, category: "transport")
    photo = report.expense_photos.create!(content_type: "image/png", data: PNG_BYTES, amount: 500)

    get "/api/v1/work_reports/#{report.id}/expense_photo",
        headers: auth_headers(@owner), params: { photo_id: photo.id }
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal PNG_BYTES, response.body.b

    get "/api/v1/work_reports/#{report.id}/expense_photo",
        headers: auth_headers(@owner), params: { photo_id: 999_999 }
    assert_response :not_found
  end

  def test_index_includes_expense_photo_metadata_without_blob
    report = @owner.work_reports.create!(work_date: Date.current, category: "transport")
    report.expense_photos.create!(content_type: "image/png", data: PNG_BYTES, amount: 700, label: "高速代")

    get "/api/v1/work_reports", headers: auth_headers(@owner),
        params: { month: Date.current.strftime("%Y-%m") }

    assert_response :success
    row = response.parsed_body["reports"].find { |r| r["id"] == report.id }
    assert_equal 1, row["expense_photos"].size
    assert_equal 700, row["expense_photos"].first["amount"]
    refute row["expense_photos"].first.key?("data")
  end

  def test_read_expense_returns_ai_result
    original = ExpensePhotoReader.method(:call)
    ExpensePhotoReader.singleton_class.send(:define_method, :call) do |_bytes, _content_type|
      { amount: 1450, label: "高速代(ETC)", confidence: 95 }
    end
    begin
      post "/api/v1/work_reports/read_expense", headers: auth_headers(@owner),
           params: { file: Rack::Test::UploadedFile.new(StringIO.new(PNG_BYTES), "image/png", original_filename: "receipt.png") }
    ensure
      ExpensePhotoReader.singleton_class.send(:define_method, :call, original)
    end

    assert_response :success
    assert_equal 1450, response.parsed_body["amount"]
    assert_equal "高速代(ETC)", response.parsed_body["label"]
  end

  def test_read_expense_requires_file
    post "/api/v1/work_reports/read_expense", headers: auth_headers(@owner)

    assert_response :unprocessable_entity
  end

  def test_expense_photo_content_type_whitelisted_on_save
    post "/api/v1/work_reports", headers: auth_headers(@owner), params: {
      work_date: Date.current.iso8601, category: "transport",
      expense_photos_add: [ { data_base64: "data:text/html;base64,#{Base64.strict_encode64('<script>alert(1)</script>')}" } ]
    }, as: :json

    assert_response :created
    report = @owner.work_reports.find(response.parsed_body["id"])
    assert_equal "image/jpeg", report.expense_photos.first.content_type
  end
end
