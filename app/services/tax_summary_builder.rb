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

  # ラボップは統合請求書で西野に全額(外注パートナー分込み)を振り込む運用。
  # → 対象パートナーと合算開始月は users.subcontract_from で管理する(川村=2026-04〜、須崎=2026-06〜)。
  # 開始月以降の承認済み請求は「西野の売上」に合算し、同額を「外注工賃」として経費計上する。

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
      consumption_tax: consumption_tax_block(income_total, expenses),
      income_items: income_items(incomes, subcontract)
    }
  end

  # 売上の内訳(クリックで詳細表示用): 自分の請求 + パートナー合算分を月順で返す
  def income_items(incomes, subcontract)
    (incomes.map { |s| income_item(s, "own") } + subcontract.map { |s| income_item(s, "subcontract") })
      .sort_by { |row| [ row[:month], row[:source] ] }
  end

  def income_item(submission, source)
    {
      month: submission.month,
      user_name: submission.user&.display_name,
      category: submission.category,
      total: submission.total_override.to_i,
      source: source, # own=自分の請求 / subcontract=パートナー合算(同額を外注工賃で控除)
      note: submission.note
    }
  end

  private

  # 承認済み請求を admin の売上に合算 & 外注工賃で控除する対象パートナー。
  # 対象と開始月は users.subcontract_from で管理する(null=対象外)。
  def subcontract_incomes
    return @subcontract_incomes if defined?(@subcontract_incomes)
    return @subcontract_incomes = [] unless @user.admin?
    partners = User.where.not(subcontract_from: nil).where.not(id: @user.id)
    return @subcontract_incomes = [] if partners.empty?
    @subcontract_incomes = partners.flat_map do |partner|
      started_year = partner.subcontract_from.year
      next [] if started_year > @year
      scope = InvoiceSubmission.where(user_id: partner.id, kind: "invoice", status: "approved", year: @year)
      scope = scope.where("month >= ?", partner.subcontract_from.month) if started_year == @year
      scope.includes(:user).to_a
    end
  end

  # 小規模事業者の特例納税割合（納付税額 = 売上税額 × この割合）。
  # 〜2026年分(令和8年分)は「2割特例」。2026年度税制改正で個人事業者に限り
  # 2027・2028年分(令和9・10年分)は納付3割の「3割特例」として延長された。
  # 2029年分以降は特例終了予定（簡易課税 or 一般課税）なので、その時に要見直し。
  # https://www.nta.go.jp/taxes/shiraberu/zeimokubetsu/shohi/keigenzeiritsu/invoice-review/index.htm
  def special_payment_rate
    @year <= 2026 ? 0.2 : 0.3
  end

  def special_label
    special_payment_rate == 0.2 ? "2割特例" : "3割特例"
  end

  # 消費税の概算（インボイス課税事業者前提）。
  # - sales_tax: 売上に含まれる消費税(税込×10/110)
  # - special20: 2割特例/3割特例の納税見込み(売上税額×特例割合・百円未満切捨て)
  # - general_estimate: 一般課税の概算(売上税額 − 仕入税額控除)
  #   ※外注費の仕入税額控除は、パートナーの users.invoice_registered で判定:
  #     登録済み(課税事業者)=100%控除 / 免税事業者=経過措置80%(〜2026/9)
  def consumption_tax_block(income_total, expenses)
    sales_tax = (income_total * 10 / 110.0).floor
    taxable_expenses = expenses.select { |e| e.tax_rate.to_i.positive? }.sum(&:deductible_amount)
    expense_tax = (taxable_expenses * 10 / 110.0).floor

    # 外注費の税額はパートナーごとにインボイス登録の有無で控除率を分ける
    subcontract_tax = subcontract_incomes.group_by(&:user).sum do |partner, submissions|
      tax = (submissions.sum { |s| s.total_override.to_i } * 10 / 110.0).floor
      partner.invoice_registered? ? tax : (tax * 0.8).floor
    end

    purchase_tax = expense_tax + subcontract_tax
    general_estimate = [ sales_tax - purchase_tax, 0 ].max / 100 * 100

    # 2割特例/3割特例の正式計算(付表6・実申告と同一方式):
    # 税抜対価 → 課税標準額(千円切捨て) → 国税7.8% → 特別控除(1−特例割合) → 差引(百円切捨て) → 地方22/78(百円切捨て)
    taxable_base_raw = (income_total * 100 / 110.0).floor   # 課税資産の譲渡等の対価の額(税抜)
    taxable_base = taxable_base_raw / 1000 * 1000            # 課税標準額
    national_tax = (taxable_base * 0.078).floor              # 消費税額(国税7.8%)
    special_deduction = (national_tax * (1 - special_payment_rate)).floor # 特別控除税額(2割特例=80% / 3割特例=70%)
    national_payment = (national_tax - special_deduction) / 100 * 100 # 差引税額(百円切捨て)
    local_payment = (national_payment * 22 / 78.0).floor / 100 * 100  # 地方消費税(22/78)
    special20 = national_payment + local_payment

    {
      taxable_sales: income_total,
      sales_tax: sales_tax,
      purchase_tax: purchase_tax,
      special20_payment: special20,
      special_rate_percent: (special_payment_rate * 100).round, # 20=2割特例 / 30=3割特例
      special_label: special_label,
      general_estimate: general_estimate,
      recommended: special20 <= general_estimate ? "special20" : "general",
      partner_invoice_registered: subcontract_incomes.map(&:user).uniq.all?(&:invoice_registered?),
      # 消費税申告書(2割特例)の記載値
      breakdown: {
        taxable_base_raw: taxable_base_raw,
        taxable_base: taxable_base,
        national_tax: national_tax,
        special_deduction: special_deduction,
        national_payment: national_payment,
        local_payment: local_payment,
        total_payment: special20
      }
    }
  end
end
