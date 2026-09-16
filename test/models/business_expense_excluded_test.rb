require "test_helper"

# 経費の「対象外」(status=excluded): 行は残したまま計上額 0・集計から除外。
# 削除だと freee 再取込(import_hash で重複判定)で復活するため、削除の代わりに使う。
class BusinessExpenseExcludedTest < Minitest::Test
  def setup
    @owner = User.create!(
      email: "excluded_owner_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "対象外テスト"
    )
  end

  def teardown
    @owner.business_expenses.destroy_all
    @owner.destroy
  end

  def create_expense(amount:, status: "confirmed", excluded_reason: nil)
    @owner.business_expenses.create!(
      expense_date: Date.new(2026, 3, 6), store_name: "テスト店", amount: amount, tax_rate: 10,
      account_category: "接待交際費", business_ratio: 100, status: status, excluded_reason: excluded_reason,
      source: "freee", import_hash: "freee_deal:test:#{SecureRandom.hex(3)}"
    )
  end

  def test_excluded_is_an_allowed_status
    expense = create_expense(amount: 33_000, status: "excluded", excluded_reason: "領収書金額と摘要が不一致")

    assert expense.excluded?
    assert_equal "領収書金額と摘要が不一致", expense.excluded_reason
  end

  def test_excluded_expense_has_zero_deductible_amount
    expense = create_expense(amount: 33_000, status: "excluded")

    assert_equal 0, expense.deductible_amount
  end

  def test_counted_scope_omits_excluded_rows
    counted = create_expense(amount: 1_000)
    create_expense(amount: 33_000, status: "excluded")

    assert_equal [ counted.id ], @owner.business_expenses.counted.pluck(:id)
  end

  def test_tax_summary_ignores_excluded_expenses
    create_expense(amount: 1_000)
    create_expense(amount: 33_000, status: "excluded")

    summary = TaxSummaryBuilder.call(@owner, 2026)

    assert_equal 1_000, summary[:expense_total]
    assert_equal 1, summary[:expense_count]
  end

  # 対象外の行が残っていれば、同じ import_hash の再取込は既存扱いになる(復活しない)
  def test_excluded_row_keeps_import_hash_for_duplicate_detection
    expense = create_expense(amount: 33_000, status: "excluded")

    assert @owner.business_expenses.exists?(import_hash: expense.import_hash)
  end
end
