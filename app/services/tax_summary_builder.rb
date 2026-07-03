# 確定申告用の年間集計を組み立てる単一窓口。
# 売上=承認済みの本人請求書(invoice_submissions) / 経費=business_expenses(家事按分後) / 減価償却=fixed_assets(定額法)。
# TaxReportsController(JSON/CSV) と TaxReturnPdfRenderer(決算書PDF) の両方から使う。
class TaxSummaryBuilder
  def self.call(user, year)
    new(user, year).call
  end

  def initialize(user, year)
    @user = user
    @year = year
  end

  def call
    expenses = @user.business_expenses.where(expense_date: Date.new(@year, 1, 1)..Date.new(@year, 12, 31)).to_a
    incomes = InvoiceSubmission.where(user_id: @user.id, kind: "invoice", status: "approved", year: @year).to_a
    assets = @user.fixed_assets.to_a
    depreciation_total = assets.sum { |a| a.depreciation_for(@year) }

    by_category = expenses.group_by(&:account_category).map do |category, rows|
      { category: category || "未分類", total: rows.sum(&:deductible_amount), count: rows.size }
    end
    by_category << { category: "減価償却費", total: depreciation_total, count: assets.size } if depreciation_total.positive?
    by_category = by_category.sort_by { |row| -row[:total] }

    income_by_month = (1..12).map { |m| incomes.select { |s| s.month == m }.sum { |s| s.total_override.to_i } }
    expense_by_month = (1..12).map { |m| expenses.select { |e| e.expense_date&.month == m }.sum(&:deductible_amount) }
    income_total = income_by_month.sum
    expense_total = by_category.sum { |row| row[:total] }

    {
      year: @year,
      income_total: income_total,
      expense_total: expense_total,
      depreciation_total: depreciation_total,
      profit: income_total - expense_total,
      by_category: by_category,
      monthly: (1..12).map { |m| { month: m, income: income_by_month[m - 1], expense: expense_by_month[m - 1] } },
      expense_count: expenses.size,
      needs_review_count: expenses.count { |e| e.status == "needs_review" }
    }
  end
end
