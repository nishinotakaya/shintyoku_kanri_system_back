class WorkReport < ApplicationRecord
  belongs_to :user
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :meter_photos, class_name: "WorkReportMeterPhoto", dependent: :destroy

  CATEGORIES = %w[wings living techleaders resystems proaka transport].freeze

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

  before_save :recalculate_hours_from_clock, if: :recalculate_hours?

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

  # 開始・終了時間から稼働時間(hours)を出す。
  # 以前は打刻ボタン(clock_out API)だけが hours を入れていたため、カレンダーや
  # 稼働報告書から時間を入力した日は hours が 0 のままで、勤怠の合計・請求金額が 0 になっていた。
  def self.worked_hours_between(clock_in, clock_out, break_minutes = 0)
    return nil if clock_in.blank? || clock_out.blank?

    minutes = ((clock_out - clock_in) / 60).round
    minutes += 24 * 60 if minutes.negative? # 日をまたいだ稼働
    minutes -= break_minutes.to_i
    ([ minutes, 0 ].max / 60.0).round(2)
  end

  private

  # 開始・終了がそろっていて、時間の手入力が無いときだけ再計算する。
  # hours を明示的に書き換えた保存では手入力を優先する。
  def recalculate_hours?
    return false if clock_in.blank? || clock_out.blank?
    return false if will_save_change_to_hours?

    hours.to_f.zero? || will_save_change_to_clock_in? ||
      will_save_change_to_clock_out? || will_save_change_to_break_minutes?
  end

  def recalculate_hours_from_clock
    self.hours = self.class.worked_hours_between(clock_in, clock_out, break_minutes)
  end

  def meter_end_must_not_be_less_than_meter_start
    return if meter_start.blank? || meter_end.blank?
    return if meter_end >= meter_start

    errors.add(:meter_end, "は開始メーターより小さい値にできません")
  end
end
