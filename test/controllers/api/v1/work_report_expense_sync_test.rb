require "test_helper"

# 日報 → 立替金の自動同期。
#   ・実費レシート(transport)   … レシート1枚 = 立替金1件(work_report_expense_photo_id で紐付け)
#   ・乗車区間(transit_section) … 1日1件の立替金(from_station/to_station あり)
# どちらも「自動で作った行」だけを更新・削除し、手入力の立替金には触れないことを検証する。
class Api::V1::WorkReportExpenseSyncTest < ActionDispatch::IntegrationTest
  def setup
    @owner = User.create!(email: "expense_sync_owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "運送 次郎", closing_day: 31)
  end

  def teardown
    @owner&.destroy
  end

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def data_url
    png_bytes = Base64.decode64(
      "iVBORw0KGgoAAAABAMAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
    "data:image/png;base64,#{Base64.strict_encode64(png_bytes)}"
  end

  # 1) transport の日報にレシート2枚(金額あり)を付けて保存 → 立替金が2件作られ、
  #    用途・金額・日付・category が正しい
  def test_transport_receipts_create_matching_expenses
    work_date = Date.current

    post "/api/v1/work_reports", headers: auth_headers(@owner), params: {
      work_date: work_date.iso8601, category: "transport",
      expense_photos_add: [
        { data_base64: data_url, amount: 1200, label: "高速代(ETC)" },
        { data_base64: data_url, amount: 600, label: "駐車場代" }
      ]
    }, as: :json

    assert_response :created
    report = @owner.work_reports.find(response.parsed_body["id"])

    expenses = @owner.expenses.where(expense_date: work_date, category: "transport").order(:id)
    assert_equal 2, expenses.count
    assert_equal [ "高速代(ETC)", "駐車場代" ], expenses.map(&:purpose)
    assert_equal [ 1200, 600 ], expenses.map(&:amount)
    assert_equal [ work_date, work_date ], expenses.map(&:expense_date)
    assert_equal [ "transport", "transport" ], expenses.map(&:category)
    assert_equal [ "有", "有" ], expenses.map(&:receipt_no)
    assert_equal report.expense_photos.order(:id).pluck(:id), expenses.map(&:work_report_expense_photo_id)
  end

  # 2) 同じ内容でもう一度保存 → 立替金は2件のまま(冪等・重複しない)
  def test_saving_again_does_not_duplicate_expenses
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "transport")
    photo_a = report.expense_photos.create!(content_type: "image/png", data: "x", amount: 1200, label: "高速代")
    photo_b = report.expense_photos.create!(content_type: "image/png", data: "x", amount: 600, label: "駐車場代")

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {}, as: :json
    assert_response :success
    assert_equal 2, @owner.expenses.where(expense_date: work_date, category: "transport").count

    # もう一度同じ内容で保存
    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {}, as: :json
    assert_response :success

    expenses = @owner.expenses.where(expense_date: work_date, category: "transport").order(:id)
    assert_equal 2, expenses.count
    assert_equal [ photo_a.id, photo_b.id ], expenses.map(&:work_report_expense_photo_id)
  end

  # 3) レシートの金額を expense_photos_update で直して保存 → 紐付いた立替金の金額も変わる
  def test_updating_receipt_amount_updates_linked_expense
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "transport")
    photo = report.expense_photos.create!(content_type: "image/png", data: "x", amount: 1200, label: "高速代")
    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {}, as: :json
    assert_response :success
    expense = @owner.expenses.find_by(work_report_expense_photo_id: photo.id)
    assert_equal 1200, expense.amount

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      expense_photos_update: [ { id: photo.id, amount: 1500, label: "高速代(修正)" } ]
    }, as: :json

    assert_response :success
    expense.reload
    assert_equal 1500, expense.amount
    assert_equal "高速代(修正)", expense.purpose
  end

  # 4) レシートを remove_expense_photo_ids で消して保存 → 紐付いた立替金も消える
  def test_removing_receipt_deletes_linked_expense
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "transport")
    photo = report.expense_photos.create!(content_type: "image/png", data: "x", amount: 1200, label: "高速代")
    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {}, as: :json
    assert_response :success
    assert @owner.expenses.exists?(work_report_expense_photo_id: photo.id)

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      remove_expense_photo_ids: [ photo.id ]
    }, as: :json

    assert_response :success
    refute @owner.expenses.exists?(work_report_expense_photo_id: photo.id)
  end

  # 5) 回帰テスト: transport の同じ日に手入力した立替金(from_station/to_station なし)がある状態で
  #    日報を保存 → その立替金が消えない
  def test_manual_expense_without_stations_is_not_deleted_on_report_save
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "transport")
    manual_expense = @owner.expenses.create!(
      expense_date: work_date, category: "transport", purpose: "ガソリン代", amount: 3000
    )

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      distance_km: 120
    }, as: :json

    assert_response :success
    assert @owner.expenses.exists?(manual_expense.id)
    manual_expense.reload
    assert_equal "ガソリン代", manual_expense.purpose
    assert_equal 3000, manual_expense.amount
    assert_nil manual_expense.work_report_expense_photo_id
  end

  # 6) wings の日報で transit_section + transit_fee → 立替金1件。区間を空にして保存 → その交通費の
  #    立替金は消えるが、同じ日の手入力立替金(区間なし)は残る
  def test_wings_transit_section_sync_and_manual_expense_survives_clearing
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "wings")

    manual_expense = @owner.expenses.create!(
      expense_date: work_date, category: "wings", purpose: "備品購入", amount: 500
    )

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      transit_section: "東京 ~ 品川", transit_fee: 200
    }, as: :json
    assert_response :success

    transit_expense = @owner.expenses.find_by(
      expense_date: work_date, category: "wings", from_station: "東京", to_station: "品川"
    )
    assert transit_expense, "乗車区間から立替金が作られていない"
    assert_equal 200, transit_expense.amount
    assert @owner.expenses.exists?(manual_expense.id), "手入力の立替金が消えてはいけない"

    # 区間を空にして保存
    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      transit_section: "", transit_fee: nil
    }, as: :json
    assert_response :success

    refute @owner.expenses.exists?(transit_expense.id), "区間を消したら自動作成の交通費立替金は消えるべき"
    assert @owner.expenses.exists?(manual_expense.id), "区間なしの手入力立替金は残るべき"
  end

  # 7) レシートの amount が nil のときは立替金が作られない
  def test_receipt_without_amount_does_not_create_expense
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "transport")
    photo = report.expense_photos.create!(content_type: "image/png", data: "x", amount: nil, label: "不明な領収書")

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {}, as: :json

    assert_response :success
    refute @owner.expenses.exists?(work_report_expense_photo_id: photo.id)
  end

  # 7-2) amount ありで作成済みの立替金が、金額を 0 に更新すると削除される
  def test_receipt_amount_dropped_to_zero_removes_expense
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "transport")
    photo = report.expense_photos.create!(content_type: "image/png", data: "x", amount: 1000, label: "駐車場代")
    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {}, as: :json
    assert_response :success
    assert @owner.expenses.exists?(work_report_expense_photo_id: photo.id)

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {
      expense_photos_update: [ { id: photo.id, amount: 0 } ]
    }, as: :json

    assert_response :success
    refute @owner.expenses.exists?(work_report_expense_photo_id: photo.id)
  end

  # 8) living の日報にはレシート同期が走らない
  def test_living_report_does_not_sync_receipts
    work_date = Date.current
    report = @owner.work_reports.create!(work_date: work_date, category: "living")
    photo = report.expense_photos.create!(content_type: "image/png", data: "x", amount: 1200, label: "高速代")

    patch "/api/v1/work_reports/#{report.id}", headers: auth_headers(@owner), params: {}, as: :json

    assert_response :success
    refute @owner.expenses.exists?(work_report_expense_photo_id: photo.id)
    assert_equal 0, @owner.expenses.where(expense_date: work_date, category: "living").count
  end
end
