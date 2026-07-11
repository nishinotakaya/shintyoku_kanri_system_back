require "test_helper"

# BusinessExpensesController#bulk_destroy は current_user.business_expenses.where(id: ids).destroy_all
# を使う。ここでは同じスコープ経由で「他人の経費は消せない」ことを回帰ガードする。
class BusinessExpenseTest < Minitest::Test
  def setup
    @owner = User.create!(
      email: "expense_owner_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "経費オーナー"
    )
    @other_user = User.create!(
      email: "expense_other_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "別ユーザー"
    )
  end

  def teardown
    @owner.business_expenses.destroy_all
    @other_user.business_expenses.destroy_all
    @owner.destroy
    @other_user.destroy
  end

  def test_bulk_destroy_scope_removes_only_owner_records
    own_expense = create_expense(@owner)
    other_expense = create_expense(@other_user)

    deleted = @owner.business_expenses.where(id: [ own_expense.id, other_expense.id ]).destroy_all

    assert_equal [ own_expense.id ], deleted.map(&:id)
    refute BusinessExpense.exists?(own_expense.id)
    assert BusinessExpense.exists?(other_expense.id), "他人の経費が削除されてはいけない"
  end

  def test_bulk_destroy_scope_ignores_ids_belonging_to_other_users_entirely
    other_expense = create_expense(@other_user)

    deleted = @owner.business_expenses.where(id: [ other_expense.id ]).destroy_all

    assert_empty deleted
    assert BusinessExpense.exists?(other_expense.id)
  end

  private

  def create_expense(user)
    user.business_expenses.create!(
      expense_date: Date.new(2026, 6, 1),
      store_name: "テスト店",
      amount: 1000,
      tax_rate: 10,
      account_category: "消耗品費",
      status: "confirmed"
    )
  end
end
