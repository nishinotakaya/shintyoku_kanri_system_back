require "open3"
require "json"
require "date"

# 進捗管理 Excel をパースし、実績日ベースで各営業日の作業内容と工数を
# 確定的に振り分ける。OpenAI は使わない。
#
# ロジック:
# 1. Excel からタスク一覧（タイトル, SAP番号, 実績開始〜終了）を抽出
# 2. 対象期間の各営業日（土日祝除く）に、その日に実績期間が重なるタスクを集める
# 3. その日の total_hours をタスク数で按分
# 4. content を「SAP-3838(2)/経費購買テスト(5.5)」形式で生成
class ProgressImporter
  PARSER = Rails.root.join("lib/exporters/parse_progress.py")

  HOLIDAYS_2026 = %w[
    2026-01-01 2026-01-13 2026-02-11 2026-02-23 2026-03-20
    2026-04-29 2026-05-03 2026-05-04 2026-05-05 2026-05-06
    2026-07-20 2026-08-11 2026-09-21 2026-09-22 2026-09-23
    2026-10-12 2026-11-03 2026-11-23 2026-12-23
  ].map { |d| Date.parse(d) }.to_set.freeze

  def initialize(user:, file:, year:, month:, daily_hours: 7.5)
    @user = user
    @file = file
    @year = year
    @month = month
    @daily_hours = daily_hours.to_f
  end

  def call
    tasks = parse_excel
    period = @user.period_for(@year, @month)
    generate_reports(tasks, period)
  end

  private

  def parse_excel
    out, err, status = Open3.capture3("python3", PARSER.to_s, @file.to_s)
    raise "parse_progress failed: #{err}" unless status.success?
    JSON.parse(out, symbolize_names: true)
  end

  def working_day?(date)
    return false if date.saturday? || date.sunday?
    return false if HOLIDAYS_2026.include?(date)
    true
  end

  MAX_TASKS_PER_DAY = 4 # 1 日に表示するタスク上限

  def generate_reports(tasks, period)
    reports = []

    # 100%完了かつ期間終了が期間開始より前のものは除外（古い完了タスクを排除）
    # ただし実績期間が対象期間内なら含める
    # 未対応（progress 0 / nil）は作業内容に含めない
    active_tasks = tasks.reject do |t|
      t[:progress].nil? || t[:progress] <= 0.0 ||
        (t[:progress] == 1.0 && Date.parse(t[:actual_end]) < period.first)
    end

    period.each do |date|
      next unless working_day?(date)

      # この日に実績期間が重なるタスクを集める
      overlapping = active_tasks.select do |t|
        ts = Date.parse(t[:actual_start])
        te = Date.parse(t[:actual_end])
        ts <= date && date <= te
      end

      next if overlapping.empty?

      # 重複タスクを short 名でマージ
      merged = {}
      overlapping.each do |t|
        key = t[:sap] || t[:short]
        merged[key] ||= t[:short]
      end

      # タスクが多すぎたら上限で切る
      items = merged.values.first(MAX_TASKS_PER_DAY)
      task_count = items.size

      # 時間を均等按分（合計 = daily_hours）
      allocated = distribute_hours(items, @daily_hours)

      content = allocated.map { |a| "#{a[:short]}(#{format_hours(a[:hours])})" }.join("/")

      reports << {
        date: date.iso8601,
        content: content,
        hours: @daily_hours
      }
    end

    reports
  end

  def distribute_hours(items, total)
    count = items.size
    base = (total / count * 2).round / 2.0 # 0.5 刻みで丸め
    result = []
    remaining = total
    items.each_with_index do |short, i|
      if i == count - 1
        h = remaining.round(1)
      else
        h = [ base, remaining - (count - i - 1) * 0.5 ].min # 残りに最低 0.5h ずつ確保
        h = (h * 2).round / 2.0
        remaining -= h
      end
      result << { short: short, hours: h }
    end
    result
  end

  def format_hours(h)
    h == h.to_i ? h.to_i.to_s : format("%.1f", h)
  end
end
