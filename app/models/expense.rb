class Expense < ApplicationRecord
  belongs_to :user

  TRANSPORT_TYPES = %w[train bus taxi shinkansen flight].freeze
  CATEGORIES = %w[wings living].freeze

  validates :expense_date, :amount, presence: true

  scope :in_range, ->(range) { where(expense_date: range).order(:expense_date, :id) }
  scope :by_category, ->(cat) { where(category: cat) }

  before_validation :auto_set_company_burden, on: :create

  # シェアラウンジ系の expense は「押上」を含むときだけ会社負担。
  # それ以外のシェアラウンジ（駒澤・新宿等）は会社負担対象外として false に自動設定。
  # 通常の交通費（シェアラウンジに該当しない）はデフォルト true のまま。
  # ユーザーが UI で手動切替したら create 後の上書きは行わない（before_validation on :create のみ）。
  def auto_set_company_burden
    location_text = "#{purpose} #{payee_or_line} #{from_station} #{to_station}"
    return unless location_text.include?("シェアラウンジ")
    self.company_burden = location_text.include?("押上")
  end
end
