# 確定申告用の事業経費（レシート1枚=1レコード）。
# 立替金(Expense=ラボップ請求用)とは別物。青色申告決算書の勘定科目で分類する。
class BusinessExpense < ApplicationRecord
  belongs_to :user

  # 勘定科目マスタ: 青色申告決算書の経費科目 + 実務頻出科目
  ACCOUNT_CATEGORIES = [
    "租税公課", "荷造運賃", "水道光熱費", "旅費交通費", "通信費",
    "広告宣伝費", "接待交際費", "損害保険料", "修繕費", "消耗品費",
    "減価償却費", "福利厚生費", "給料賃金", "外注工賃", "利子割引料",
    "地代家賃", "貸倒金", "会議費", "新聞図書費", "支払手数料",
    "車両費", "雑費"
  ].freeze

  STATUSES = %w[needs_review confirmed].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :tax_rate, inclusion: { in: [ 0, 8, 10 ] }
  validates :business_ratio, numericality: { only_integer: true, in: 1..100 }
  validates :account_category, inclusion: { in: ACCOUNT_CATEGORIES }, allow_nil: true

  scope :in_month, ->(year_month) {
    return all if year_month.blank?
    from = Date.strptime(year_month, "%Y-%m")
    where(expense_date: from..from.end_of_month)
  }

  # 経費計上額 = 税込金額 × 家事按分
  def deductible_amount
    (amount.to_i * business_ratio / 100.0).round
  end
end
