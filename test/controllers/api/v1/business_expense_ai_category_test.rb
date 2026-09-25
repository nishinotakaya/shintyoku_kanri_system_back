require "test_helper"

# 勘定科目の初期値を AI が決める経路のテスト。
#   ① 口座明細の「事業で登録」(bank_transactions#register)
#   ② 未分類のまま登録済みの経費をまとめて仕訳(business_expenses#classify_uncategorized)
# AI(TransactionCategorizer)はスタブして、判定結果ごとの status を確かめる。
class Api::V1::BusinessExpenseAiCategoryTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "keihi_ai_#{SecureRandom.hex(4)}@example.com", password: "password123",
                         display_name: "経費 太郎", closing_day: 31, feature_flags: { "keihi" => true })
  end

  def teardown
    @user&.destroy
  end

  def auth_headers
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(@user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def with_ai(results_by_description)
    original = TransactionCategorizer.method(:call)
    TransactionCategorizer.singleton_class.send(:define_method, :call) do |rows|
      rows.map { |row| row.merge(results_by_description.fetch(row[:description], { account_category: nil, confidence: 0 })) }
    end
    yield
  ensure
    TransactionCategorizer.singleton_class.send(:define_method, :call, original)
  end

  def create_txn(description:, suggested: nil, amount: 3300)
    @user.bank_transactions.create!(freee_wallet_txn_id: SecureRandom.random_number(10**12),
                                   walletable_name: "三井住友カード", payment_method: "credit_card",
                                   txn_date: Date.current, amount: amount, entry_side: "expense",
                                   description: description, suggested_account_item: suggested)
  end

  # 画面から科目を送らなければ AI が初期値を決め、確信度が高ければ確定で入る
  def test_register_uses_ai_category_when_client_sends_none
    txn = create_txn(description: "ナゾノサービスリヨウリヨウ", suggested: nil)
    with_ai({ "ナゾノサービスリヨウリヨウ" => { account_category: "支払手数料", confidence: 90 } }) do
      post "/api/v1/bank_transactions/#{txn.id}/register", headers: auth_headers, params: {}, as: :json
    end
    assert_response :success
    expense = @user.business_expenses.find(response.parsed_body["business_expense_id"])
    assert_equal "支払手数料", expense.account_category
    assert_equal "confirmed", expense.status
    assert_equal 90, expense.ai_confidence
  end

  # 摘要ルールで決まる明細は AI を呼ばずに確定する
  def test_register_prefers_merchant_rule
    txn = create_txn(description: "ＡＮＴＨＲＯＰＩＣ 11.73 USD", suggested: "交際費")
    original = TransactionCategorizer.method(:call)
    TransactionCategorizer.singleton_class.send(:define_method, :call) { |_rows| raise "AI を呼んではいけない" }
    post "/api/v1/bank_transactions/#{txn.id}/register", headers: auth_headers, params: {}, as: :json
    assert_response :success
    expense = @user.business_expenses.find(response.parsed_body["business_expense_id"])
    assert_equal "通信費", expense.account_category
    assert_equal "confirmed", expense.status
    assert_nil expense.ai_confidence
  ensure
    TransactionCategorizer.singleton_class.send(:define_method, :call, original)
  end

  # freee の科目名(アプリの科目リストに無い「交際費」)を送られても採用せず、AI の判定を使う
  def test_register_ignores_unknown_category_from_client
    txn = create_txn(description: "ナゾノインシヨクテン")
    with_ai({ "ナゾノインシヨクテン" => { account_category: "接待交際費", confidence: 80 } }) do
      post "/api/v1/bank_transactions/#{txn.id}/register", headers: auth_headers,
           params: { account_category: "交際費" }, as: :json
    end
    assert_response :success
    expense = @user.business_expenses.find(response.parsed_body["business_expense_id"])
    assert_equal "接待交際費", expense.account_category
  end

  # 確信度が低い判定は科目を入れた上で要確認に残す
  def test_register_marks_low_confidence_as_needs_review
    txn = create_txn(description: "ナゾノシヨウテン")
    with_ai({ "ナゾノシヨウテン" => { account_category: "雑費", confidence: 30 } }) do
      post "/api/v1/bank_transactions/#{txn.id}/register", headers: auth_headers, params: {}, as: :json
    end
    assert_response :success
    expense = @user.business_expenses.find(response.parsed_body["business_expense_id"])
    assert_equal "雑費", expense.account_category
    assert_equal "needs_review", expense.status
  end

  # 既に未分類で登録済みの経費を後からまとめて仕訳する。対象外と分類済みは触らない
  def test_classify_uncategorized_fills_only_uncategorized_rows
    uncategorized = @user.business_expenses.create!(expense_date: Date.current, store_name: "ナゾノブンボウグテン",
                                                    amount: 2000, status: "needs_review")
    excluded = @user.business_expenses.create!(expense_date: Date.current, store_name: "ナゾノブンボウグテン",
                                               amount: 500, status: "excluded")
    classified = @user.business_expenses.create!(expense_date: Date.current, store_name: "ナゾノブンボウグテン",
                                                 amount: 800, status: "confirmed", account_category: "雑費")

    with_ai({ "ナゾノブンボウグテン" => { account_category: "消耗品費", confidence: 88 } }) do
      post "/api/v1/business_expenses/classify_uncategorized", headers: auth_headers,
           params: { month: Date.current.strftime("%Y-%m") }, as: :json
    end
    assert_response :success
    assert_equal 1, response.parsed_body["updated"]
    assert_equal "消耗品費", uncategorized.reload.account_category
    assert_equal "needs_review", uncategorized.status, "元の要確認は勝手に確定にしない"
    assert_nil excluded.reload.account_category
    assert_equal "雑費", classified.reload.account_category
  end

  # 判定できなかった行は未分類のまま残り、件数で分かる
  def test_classify_uncategorized_reports_undecided_rows
    @user.business_expenses.create!(expense_date: Date.current, store_name: "ハンテイフノウ", amount: 1000, status: "confirmed")
    with_ai({}) do
      post "/api/v1/business_expenses/classify_uncategorized", headers: auth_headers, params: {}, as: :json
    end
    assert_response :success
    body = response.parsed_body
    assert_equal 0, body["updated"]
    assert_equal 1, body["skipped"]
  end
end
