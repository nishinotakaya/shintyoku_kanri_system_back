require "test_helper"

# 稼働報告書(運送)のメーター写真: data URL で保存 → meter_photo_kinds で有無を返し →
# meter_photo で取得 → remove_meter_*_photo で削除。read_meter はAI読取(スタブ)で km を返す。
class Api::V1::WorkReportMeterPhotosTest < ActionDispatch::IntegrationTest
  # 1x1 PNG
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze

  def setup
    @owner = User.create!(email: "meter_owner_#{SecureRandom.hex(4)}@example.com",
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

  def test_create_with_meter_photo_persists_and_reports_kind
    post "/api/v1/work_reports", headers: auth_headers(@owner), params: {
      work_date: Date.current.iso8601, category: "transport",
      meter_start: 12_000, meter_start_photo_base64: data_url
    }, as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal [ "start" ], body["meter_photo_kinds"]
    report = @owner.work_reports.find(body["id"])
    photo = report.meter_photos.find_by(kind: "start")
    assert_equal "image/png", photo.content_type
    assert_equal PNG_BYTES, photo.data
  end

  def test_update_can_remove_photo_and_meter_value
    report = @owner.work_reports.create!(work_date: Date.current, category: "transport", meter_start: 12_000)
    report.meter_photos.create!(kind: "start", content_type: "image/png", data: PNG_BYTES)

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      meter_start: nil, remove_meter_start_photo: true
    }, as: :json

    assert_response :success
    assert_equal [], response.parsed_body["meter_photo_kinds"]
    assert_nil report.reload.meter_start
    assert_empty report.meter_photos
  end

  def test_meter_photo_returns_bytes_and_404_when_missing
    report = @owner.work_reports.create!(work_date: Date.current, category: "transport")
    report.meter_photos.create!(kind: "end", content_type: "image/png", data: PNG_BYTES)

    get "/api/v1/work_reports/#{report.id}/meter_photo", headers: auth_headers(@owner), params: { kind: "end" }
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal PNG_BYTES, response.body.b

    get "/api/v1/work_reports/#{report.id}/meter_photo", headers: auth_headers(@owner), params: { kind: "start" }
    assert_response :not_found
  end

  def test_index_includes_meter_photo_kinds
    report = @owner.work_reports.create!(work_date: Date.current, category: "transport")
    report.meter_photos.create!(kind: "start", content_type: "image/png", data: PNG_BYTES)

    get "/api/v1/work_reports", headers: auth_headers(@owner),
        params: { month: Date.current.strftime("%Y-%m") }

    assert_response :success
    row = response.parsed_body["reports"].find { |r| r["id"] == report.id }
    assert_equal [ "start" ], row["meter_photo_kinds"]
  end

  def test_read_meter_returns_ai_value
    reader_class = MeterPhotoReader.singleton_class
    original = reader_class.instance_method(:call)
    reader_class.define_method(:call) { |_bytes, _content_type| { value: 123_456, confidence: 95 } }

    post "/api/v1/work_reports/read_meter", headers: auth_headers(@owner),
         params: { file: Rack::Test::UploadedFile.new(StringIO.new(PNG_BYTES), "image/png", original_filename: "meter.png") }

    assert_response :success
    assert_equal 123_456, response.parsed_body["value"]
    assert_equal 95, response.parsed_body["confidence"]
  ensure
    reader_class.define_method(:call, original)
  end

  def test_photo_content_type_is_whitelisted_against_stored_xss
    post "/api/v1/work_reports", headers: auth_headers(@owner), params: {
      work_date: Date.current.iso8601, category: "transport",
      meter_start_photo_base64: "data:text/html;base64,#{Base64.strict_encode64('<script>alert(1)</script>')}"
    }, as: :json

    assert_response :created
    report = @owner.work_reports.find(response.parsed_body["id"])
    assert_equal "image/jpeg", report.meter_photos.find_by(kind: "start").content_type

    get "/api/v1/work_reports/#{report.id}/meter_photo", headers: auth_headers(@owner), params: { kind: "start" }
    assert_equal "image/jpeg", response.media_type
  end

  def test_read_meter_requires_file
    post "/api/v1/work_reports/read_meter", headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end
end
