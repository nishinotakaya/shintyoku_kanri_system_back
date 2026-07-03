# 減価償却資産。定額法・月割で各年の償却費を計算する（残存簿価1円まで）。
class FixedAsset < ApplicationRecord
  belongs_to :user

  validates :name, presence: true
  validates :cost, numericality: { only_integer: true, greater_than: 0 }
  validates :useful_life_years, numericality: { only_integer: true, in: 2..50 }
  validates :business_ratio, numericality: { only_integer: true, in: 1..100 }

  # 指定年の償却費(事業按分後)。定額法・月割。
  def depreciation_for(year)
    return 0 if year < acquired_on.year
    annual = (cost / useful_life_years.to_f).floor
    months = months_in_service(year)
    return 0 if months <= 0
    amount = (annual * months / 12.0).floor
    # 累計が (取得価額 - 備忘価額1円) を超えないよう最終年で調整
    accumulated_before = (acquired_on.year...year).sum { |y| raw_depreciation(y, annual) }
    remaining = cost - 1 - accumulated_before
    [ [ amount, remaining ].min, 0 ].max.then { |a| (a * business_ratio / 100.0).round }
  end

  private

  def months_in_service(year)
    return 0 if year < acquired_on.year
    year == acquired_on.year ? (13 - acquired_on.month) : 12
  end

  def raw_depreciation(year, annual)
    months = months_in_service(year)
    (annual * months / 12.0).floor
  end
end
