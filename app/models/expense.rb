class Expense < ApplicationRecord
  belongs_to :user

  TRANSPORT_TYPES = %w[train bus taxi shinkansen flight].freeze
  CATEGORIES = %w[wings living].freeze

  validates :expense_date, :amount, presence: true

  scope :in_range, ->(range) { where(expense_date: range).order(:expense_date, :id) }
  scope :by_category, ->(cat) { where(category: cat) }

  # 請求月で抽出: billing_month を明示している分はそれを優先、未設定(nil)の分は従来どおり
  # expense_date と締日(period)で判定する。mp は "YYYY-MM"、range は period_for の範囲。
  scope :billed_in, ->(mp, range) {
    where("billing_month = :mp OR (billing_month IS NULL AND expense_date BETWEEN :from AND :to)",
          mp: mp, from: range.first, to: range.last).order(:expense_date, :id)
  }

  # purpose 等の場所情報が新規登録 or 更新された時に再評価する（手動切替を尊重するため、
  # 場所情報が触られていない時は走らない＝ user の意図的な on/off を上書きしない）
  TRIGGER_FIELDS = %w[purpose payee_or_line from_station to_station].freeze
  before_validation :reclassify_company_burden_and_excel
  def reclassify_company_burden_and_excel
    return unless new_record? || TRIGGER_FIELDS.any? { |f| public_send("#{f}_changed?") }
    location_text = "#{purpose} #{payee_or_line} #{from_station} #{to_station}"
    if location_text.include?("シェアラウンジ")
      self.company_burden = location_text.include?("押上")
      self.excel_excluded = true
    end
  end
end
