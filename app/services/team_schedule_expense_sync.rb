require "date"

# team_schedules の status が "出社" の日に、対応ユーザーの default_transit_* を使って
# Expense + 業務報告 (work_report) を自動作成する。すでに同 date+user の同区間 Expense があれば作らない (idempotent)。
#
# - person → user マッピングは display_name の部分一致 (e.g. "西野" → 西野 鷹也)
# - 既存ロジック (BacklogToWorkReportService) が backlog_tasks に依存して
#   交通費を作っていた問題を分離するための専用同期。
class TeamScheduleExpenseSync
  COMMUTE_KEYWORDS = [ "出社" ].freeze

  def initialize(user:, year: nil, month: nil, category: "wings")
    @user = user
    @year = year
    @month = month
    @category = category
  end

  def call
    return [] if missing_transit_defaults?

    person = self.class.person_for(@user)
    return [] if person.blank?

    period = @user.period_for(@year, @month)
    schedules = TeamSchedule.where(person: person, date: period).select { |t| commute?(t.status) }

    schedules.flat_map { |schedule| sync_one(schedule.date) }
  end

  # 単一日付に対する sync。team_schedules#update / #create から呼ばれる。
  # 戻り値: 新規作成 Expense のリスト ([] なら何も作らなかった)
  def sync_one(date)
    return [] if missing_transit_defaults?

    from = @user.default_transit_from
    to = @user.default_transit_to
    created = []

    expense = @user.expenses.find_or_initialize_by(
      expense_date: date, category: @category, from_station: from, to_station: to
    )
    if expense.new_record?
      expense.assign_attributes(
        purpose: "顧客先出張",
        transport_type: "train",
        round_trip: true,
        receipt_no: "無",
        amount: @user.default_transit_fee,
        payee_or_line: @user.default_transit_line,
        company_burden: true
      )
      expense.save!
      created << expense
    end

    # 業務報告 (work_report) にも乗車区間 / 交通費を反映
    # 空欄のフィールドだけ充填する (既存値は触らない)
    wr = @user.work_reports.find_or_initialize_by(work_date: date, category: @category)
    changed = wr.new_record?
    if wr.transit_section.blank?
      wr.transit_section = "#{from} 〜 #{to}"
      changed = true
    end
    if wr.transit_fee.to_i <= 0
      wr.transit_fee = @user.default_transit_fee
      changed = true
    end
    wr.save! if changed

    created
  end

  # User.display_name から TeamSchedule.person ("大隅" / "川村" / "西野") へ逆引き
  def self.person_for(user)
    name = user.display_name.to_s
    TeamScheduleImporter::PERSONS.find { |person_name| name.include?(person_name) }
  end

  # TeamSchedule.person ("川村" 等) から実ユーザを引く。
  # wing-prefix の別アカウントは除外し、admin 本体に当たるレコードを優先。
  def self.user_for(person_name)
    User.where("display_name LIKE ?", "%#{person_name}%")
        .find_each
        .reject { |u| u.display_name.to_s.start_with?("wing") }
        .first
  end

  private

  def missing_transit_defaults?
    @user.default_transit_from.blank? || @user.default_transit_to.blank? || @user.default_transit_fee.to_i <= 0
  end

  def commute?(status)
    text = status.to_s
    COMMUTE_KEYWORDS.any? { |keyword| text.include?(keyword) }
  end
end
