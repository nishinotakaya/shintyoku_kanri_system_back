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

  # 2026年4月以降、ラボップは統合請求書で西野に全額(川村分込み)を振り込む運用。
  # → 4月以降の川村さんの承認済み請求は「西野の売上」に合算し、同額を「外注工賃」として経費計上する。
  SUBCONTRACT_FROM = { 2026 => 4 }.freeze # 年 => 合算開始月

  def call
    expenses = @user.business_expenses.where(expense_date: Date.new(@year, 1, 1)..Date.new(@year, 12, 31)).to_a
    incomes = InvoiceSubmission.where(user_id: @user.id, kind: "invoice", status: "approved", year: @year).to_a
    subcontract = subcontract_incomes
    assets = @user.fixed_assets.to_a
    depreciation_total = assets.sum { |a| a.depreciation_for(@year) }

    by_category = expenses.group_by(&:account_category).map do |category, rows|
      { category: category || "未分類", total: rows.sum(&:deductible_amount), count: rows.size }
    end
    by_category << { category: "減価償却費", total: depreciation_total, count: assets.size } if depreciation_total.positive?
    subcontract_total = subcontract.sum { |s| s.total_override.to_i }
    if subcontract_total.positive?
      outsourcing = by_category.find { |row| row[:category] == "外注工賃" }
      if outsourcing
        outsourcing[:total] += subcontract_total
        outsourcing[:count] += subcontract.size
      else
        by_category << { category: "外注工賃", total: subcontract_total, count: subcontract.size }
      end
    end
    by_category = by_category.sort_by { |row| -row[:total] }

    income_by_month = (1..12).map do |m|
      incomes.select { |s| s.month == m }.sum { |s| s.total_override.to_i } +
        subcontract.select { |s| s.month == m }.sum { |s| s.total_override.to_i }
    end
    expense_by_month = (1..12).map do |m|
      expenses.select { |e| e.expense_date&.month == m }.sum(&:deductible_amount) +
        subcontract.select { |s| s.month == m }.sum { |s| s.total_override.to_i }
    end
    income_total = income_by_month.sum
    expense_total = by_category.sum { |row| row[:total] }

    {
      year: @year,
      income_total: income_total,
      expense_total: expense_total,
      depreciation_total: depreciation_total,
      subcontract_total: subcontract_total,
      profit: income_total - expense_total,
      by_category: by_category,
      monthly: (1..12).map { |m| { month: m, income: income_by_month[m - 1], expense: expense_by_month[m - 1] } },
      expense_count: expenses.size,
      needs_review_count: expenses.count { |e| e.status == "needs_review" },
      consumption_tax: consumption_tax_block(income_total, expenses, subcontract_total)
    }
  end

  private

  # 4月以降の川村さん(非admin)の承認済み請求 = 西野の売上に合算 & 外注工賃で控除する対象
  def subcontract_incomes
    from_month = SUBCONTRACT_FROM[@year]
    return [] unless from_month && @user.admin?
    partner_ids = User.where("display_name LIKE ?", "%川村%").pluck(:id)
    return [] if partner_ids.empty?
    InvoiceSubmission.where(user_id: partner_ids, kind: "invoice", status: "approved", year: @year)
                     .where("month >= ?", from_month).to_a
  end

  # 消費税の概算（インボイス課税事業者前提）。
  # - sales_tax: 売上に含まれる消費税(税込×10/110)
  # - special20: 2割特例の納税見込み(売上税額×20%・百円未満切捨て)
  # - general_estimate: 一般課税の概算(売上税額 − 仕入税額控除。外注費・課税経費の税額を控除)
  def consumption_tax_block(income_total, expenses, subcontract_total)
    sales_tax = (income_total * 10 / 110.0).floor
    taxable_expenses = expenses.select { |e| e.tax_rate.to_i.positive? }.sum(&:deductible_amount) + subcontract_total
    purchase_tax = (taxable_expenses * 10 / 110.0).floor
    special20 = (sales_tax * 0.2).floor / 100 * 100
    general_estimate = [ sales_tax - purchase_tax, 0 ].max / 100 * 100
    {
      taxable_sales: income_total,
      sales_tax: sales_tax,
      purchase_tax: purchase_tax,
      special20_payment: special20,
      general_estimate: general_estimate,
      recommended: special20 <= general_estimate ? "special20" : "general"
    }
  end
end
