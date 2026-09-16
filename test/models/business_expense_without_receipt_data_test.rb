require "test_helper"

# 一覧・集計でレシート画像(receipt_data)の BLOB を読まないためのスコープ。
# 1 年分を全列で読むと数百 MB を確保して本番(1GB)が OOM で落ちた(2026-09-16)ことへの回帰ガード。
class BusinessExpenseWithoutReceiptDataTest < Minitest::Test
  def setup
    @owner = User.create!(
      email: "receipt_scope_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "レシートスコープテスト"
    )
    @with_receipt = create_expense(receipt_data: "\xFF\xD8fake-jpeg-bytes".b, content_type: "image/jpeg")
    @without_receipt = create_expense(receipt_data: nil)
  end

  def teardown
    @owner.business_expenses.destroy_all
    @owner.destroy
  end

  def create_expense(receipt_data:, content_type: nil)
    @owner.business_expenses.create!(
      expense_date: Date.new(2026, 3, 6), store_name: "テスト店", amount: 1_000, tax_rate: 10,
      account_category: "消耗品費", business_ratio: 100, status: "confirmed",
      receipt_data: receipt_data, content_type: content_type
    )
  end

  def test_scope_does_not_load_the_receipt_blob
    row = @owner.business_expenses.without_receipt_data.find(@with_receipt.id)

    refute row.has_attribute?(:receipt_data), "BLOB 列を SELECT してはいけない"
    assert row.has_attribute?(:receipt_attached)
  end

  def test_receipt_attached_reflects_presence_without_reading_the_blob
    rows = @owner.business_expenses.without_receipt_data.order(:id).to_a

    assert_equal [ true, false ], rows.map(&:receipt_attached?)
  end

  def test_receipt_attached_falls_back_to_blob_when_loaded_with_all_columns
    assert @with_receipt.reload.receipt_attached?
    refute @without_receipt.reload.receipt_attached?
  end

  def test_scope_still_exposes_the_columns_used_by_the_tax_summary
    row = @owner.business_expenses.without_receipt_data.counted.find(@with_receipt.id)

    assert_equal 1_000, row.deductible_amount
    assert_equal "消耗品費", row.account_category
    assert_equal 10, row.tax_rate
  end

  def test_tax_summary_works_on_the_light_scope
    summary = TaxSummaryBuilder.call(@owner, 2026)

    assert_equal 2_000, summary[:expense_total]
    assert_equal 2, summary[:expense_count]
  end
end
