class WorkReport < ApplicationRecord
  belongs_to :user
  belongs_to :approved_by, class_name: "User", optional: true

  CATEGORIES = %w[wings living techleaders resystems transport].freeze

  # 運送業(category=transport)向けの日報項目。approved_by_id はユーザーに直接触らせず approve!/unapprove! 経由でのみ更新する。
  TRANSPORT_ATTRIBUTES = %i[distance_km delivery_count meter_start meter_end note weekly_payment approved_at].freeze

  validates :work_date, presence: true, uniqueness: { scope: [ :user_id, :category ] }
  validates :distance_km, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :delivery_count, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :meter_start, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :meter_end, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :meter_end_must_not_be_less_than_meter_start

  scope :in_range, ->(range) { where(work_date: range).order(:work_date) }
  scope :by_category, ->(cat) { where(category: cat) }

  def approved?
    approved_at.present?
  end

  # 検印を押す。所有者本人 or admin だけが呼べる想定(呼び出し元のコントローラで認可する)。
  def approve!(actor:)
    update!(approved_at: Time.current, approved_by: actor)
  end

  def unapprove!
    update!(approved_at: nil, approved_by: nil)
  end

  private

  def meter_end_must_not_be_less_than_meter_start
    return if meter_start.blank? || meter_end.blank?
    return if meter_end >= meter_start

    errors.add(:meter_end, "は開始メーターより小さい値にできません")
  end
end
