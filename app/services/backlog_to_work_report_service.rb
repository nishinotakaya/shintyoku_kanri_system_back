require "date"

# BacklogTask (DB) から WorkReport を自動生成する。
# 各営業日に、その日に実績期間が重なるタスクを割り振る。
class BacklogToWorkReportService
  HOLIDAYS_2026 = %w[
    2026-01-01 2026-01-13 2026-02-11 2026-02-23 2026-03-20
    2026-04-29 2026-05-03 2026-05-04 2026-05-05 2026-05-06
    2026-07-20 2026-08-11 2026-09-21 2026-09-22 2026-09-23
    2026-10-12 2026-11-03 2026-11-23 2026-12-23
  ].map { |d| Date.parse(d) }.to_set.freeze

  MAX_TASKS_PER_DAY = 4

  def initialize(user:, year:, month:, category: "wings", daily_hours: 8.0)
    @user = user
    @year = year
    @month = month
    @category = category
    @daily_hours = daily_hours.to_f
    @custom_off = (@user.custom_off_days || []).map { |d| Date.parse(d) rescue nil }.compact.to_set
    @commute_days = (@user.commute_days || [1, 2, 3, 4, 5]).map(&:to_i).to_set # デフォルト月〜金
  end

  def call
    period = @user.period_for(@year, @month)
    tasks = @user.backlog_tasks.where.not(status_id: nil).to_a

    reports = []
    period.each do |date|
      next if off_day?(date)

      # この日に重なるタスク: created_on <= date <= (completed_on or due_date or today+30)
      active = tasks.select do |t|
        start = t.created_on || t.start_date
        finish = t.completed_on || t.due_date || (Date.current + 30)
        next false unless start
        start <= date && date <= finish
      end

      next if active.empty?

      # SAP番号 or タイトル短縮でマージ
      merged = {}
      active.each do |t|
        key = t.issue_key.start_with?("LOCAL") ? t.summary.to_s[0..15] : t.issue_key
        merged[key] ||= key
      end

      items = merged.values.first(MAX_TASKS_PER_DAY)
      allocated = distribute_hours(items, @daily_hours)
      content = allocated.map { |a| "#{a[:short]}(#{fmt(a[:hours])})" }.join("/")

      # 通勤日（commute_days）のみ乗車区間を入れる。wday: 0=日 1=月 ... 6=土
      is_commute = @commute_days.include?(date.wday)
      reports << {
        date: date.iso8601, content: content, hours: @daily_hours,
        transit_section: is_commute && @user.default_transit_from.present? ? "#{@user.default_transit_from} ~ #{@user.default_transit_to}" : nil,
        transit_fee: is_commute ? @user.default_transit_fee : nil
      }
    end

    reports
  end

  def apply!
    reports = call
    applied = []
    ActiveRecord::Base.transaction do
      reports.each do |r|
        wr = @user.work_reports.find_or_initialize_by(work_date: r[:date], category: @category)
        wr.content = r[:content]
        wr.hours = r[:hours]
        wr.transit_section = r[:transit_section] if r[:transit_section].present?
        wr.transit_fee = r[:transit_fee] if r[:transit_fee].present?
        wr.save!

        # 立替金も自動反映
        if r[:transit_section].present? && r[:transit_fee].to_i > 0
          parts = r[:transit_section].split(/\s*[~～〜]\s*/)
          expense = @user.expenses.find_or_initialize_by(
            expense_date: r[:date], category: @category, from_station: parts[0].to_s.strip, to_station: parts[1].to_s.strip
          )
          expense.purpose ||= "顧客先出張"
          expense.transport_type ||= "train"
          expense.round_trip = true if expense.round_trip.nil?
          expense.receipt_no ||= "無"
          expense.amount = r[:transit_fee]
          expense.payee_or_line ||= @user.default_transit_line
          expense.save!
        end
        applied << wr
      end
    end
    applied
  end

  private

  def off_day?(date)
    return true if date.saturday? || date.sunday?
    return true if HOLIDAYS_2026.include?(date)
    return true if @custom_off.include?(date)
    false
  end

  def distribute_hours(items, total)
    count = items.size
    base = (total / count * 2).round / 2.0
    result = []
    remaining = total
    items.each_with_index do |short, i|
      if i == count - 1
        h = remaining.round(1)
      else
        h = [base, remaining - (count - i - 1) * 0.5].min
        h = (h * 2).round / 2.0
        remaining -= h
      end
      result << { short: short, hours: h }
    end
    result
  end

  def fmt(h)
    h == h.to_i ? h.to_i.to_s : format("%.1f", h)
  end
end
