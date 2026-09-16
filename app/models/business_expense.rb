# 確定申告用の事業経費（レシート1枚=1レコード）。
# 立替金(Expense=ラボップ請求用)とは別物。青色申告決算書の勘定科目で分類する。
class BusinessExpense < ApplicationRecord
  belongs_to :user

  # 勘定科目マスタ: 青色申告決算書の経費科目 + 実務頻出科目
  ACCOUNT_CATEGORIES = [
    "租税公課", "荷造運賃", "水道光熱費", "旅費交通費", "通信費",
    "広告宣伝費", "接待交際費", "損害保険料", "修繕費", "消耗品費",
    "減価償却費", "福利厚生費", "給料賃金", "外注工賃", "利子割引料",
    "地代家賃", "貸倒金", "会議費", "研修費", "新聞図書費", "支払手数料",
    "車両費", "雑費"
  ].freeze

  # needs_review=AI読取直後の要確認 / confirmed=確定 / excluded=対象外(事業関連性が薄いなど、行は残して集計から外す)。
  # excluded は削除の代わり。freee 取込は import_hash で重複判定するため、削除すると次回取込で復活してしまう。
  STATUSES = %w[needs_review confirmed excluded].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :tax_rate, inclusion: { in: [ 0, 8, 10 ] }
  validates :business_ratio, numericality: { only_integer: true, in: 1..100 }
  validates :account_category, inclusion: { in: ACCOUNT_CATEGORIES }, allow_nil: true

  # 集計(確定申告・月次サマリー・CSV)に含める経費 = 対象外を除いたもの
  scope :counted, -> { where.not(status: "excluded") }

  # レシート画像(receipt_data)は 1 行で数 MB になるため、一覧・集計では BLOB 本体を読まない。
  # 添付の有無だけを SQL で受け取り、画像本体は receipt アクションで 1 件ずつ読む。
  # (全列で読むと 1 年分の集計で数百 MB を確保し、本番 1GB マシンが OOM で再起動した: 2026-09-16)
  scope :without_receipt_data, -> {
    select(column_names - [ "receipt_data" ])
      .select("(receipt_data IS NOT NULL AND length(receipt_data) > 0) AS receipt_attached")
  }

  scope :in_month, ->(year_month) {
    return all if year_month.blank?
    from = Date.strptime(year_month, "%Y-%m")
    where(expense_date: from..from.end_of_month)
  }

  def excluded? = status == "excluded"

  # without_receipt_data で読んだ行は SQL の判定結果(0/1)を、全列で読んだ行は BLOB の有無を返す
  def receipt_attached?
    if has_attribute?(:receipt_attached)
      ActiveModel::Type::Boolean.new.cast(read_attribute(:receipt_attached))
    else
      receipt_data.present?
    end
  end

  # 経費計上額 = 税込金額 × 家事按分。対象外は 0 円
  def deductible_amount
    return 0 if excluded?
    (amount.to_i * business_ratio / 100.0).round
  end
end
