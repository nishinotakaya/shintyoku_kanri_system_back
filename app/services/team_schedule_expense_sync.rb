require "date"

# team_schedules の status が "出社" の日に、対応ユーザーの default_transit_* を使って
# Expense を自動作成する。すでに同 date+user+from+to の Expense があれば作らない (idempotent)。
#
# - person → user マッピングは display_name の部分一致 (e.g. "西野" → 西野 鷹也)
# - 既存ロジック (BacklogToWorkReportService) が backlog_tasks に依存して
#   交通費を作っていた問題を分離するための専用同期。
class TeamScheduleExpenseSync
  COMMUTE_KEYWORDS = [ "出社" ].freeze

  def initialize(user:, year:, month:, category: "wings")
    @user = user
    @year = year
    @month = month
    @category = category
  end

  def call
    return [] if @user.default_transit_from.blank? || @user.default_transit_to.blank? || @user.default_transit_fee.to_i <= 0

    person = person_for(@user)
    return [] if person.blank?

    period = @user.period_for(@year, @month)
    schedules = TeamSchedule.where(person: person, date: period).select { |t| commute?(t.status) }

    created = []
    schedules.each do |schedule|
      from = @user.default_transit_from
      to = @user.default_transit_to
      expense = @user.expenses.find_or_initialize_by(
        expense_date: schedule.date, category: @category, from_station: from, to_station: to
      )
      next unless expense.new_record? # 既存なら金額や line を上書きしない
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
    created
  end

  private

  def commute?(status)
    text = status.to_s
    COMMUTE_KEYWORDS.any? { |keyword| text.include?(keyword) }
  end

  # User.display_name から TeamSchedule.person ("大隅" / "川村" / "西野") へ逆引き
  def person_for(user)
    name = user.display_name.to_s
    TeamScheduleImporter::PERSONS.find { |person_name| name.include?(person_name) }
  end
end
