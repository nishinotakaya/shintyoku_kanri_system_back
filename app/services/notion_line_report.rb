# リビング(Notion WBS)タスクの進捗を LINE で報告するメッセージを組み立てる。
# 変更があった項目は「修正前 → 修正後」(修正前=前回同期値 *_prev)、変更が無ければ現在値だけを出す。
# 例:
#   タスク: 見積書 2.2.7.3.5
#   開始日: 2026/09/10 → 9/15
#   終了日: 2026/09/22
#   進捗率: 70% → 90%
#   リンク
#   https://www.notion.so/...
class NotionLineReport
  def initialize(tasks, reporter: nil)
    @tasks = tasks
    @reporter = reporter
  end

  def message
    header = "📋 進捗報告#{@reporter.present? ? "（#{@reporter}）" : ""}"
    ([ header ] + @tasks.map { |task| task_section(task) }).join("\n\n")
  end

  private

  def task_section(task)
    lines = [ "タスク: #{[ task.title, task.wbs_level.presence ].compact.join(' ')}" ]
    lines << "開始日: #{date_line(task.start_date_prev, task.start_date)}"
    lines << "終了日: #{date_line(task.end_date_prev, task.end_date)}"
    lines << "進捗率: #{rate_line(task.progress_rate_prev, task.progress_rate)}"
    lines << "ステータス: #{text_line(task.status_prev, task.status)}" if task.status.present?
    lines << "備考(遅れた理由など): #{task.note}" if task.note.present?
    lines << "リンク"
    lines << task.url
    lines.join("\n")
  end

  # 変更あり: 「2026/09/10 → 9/15」/ 変更なし: 「2026/09/10」
  def date_line(previous_date, current_date)
    return "-" if previous_date.nil? && current_date.nil?
    return full_date(current_date) if previous_date.nil? || previous_date == current_date
    "#{full_date(previous_date)} → #{short_date(current_date)}"
  end

  def full_date(date) = date ? date.strftime("%Y/%m/%d") : "-"
  def short_date(date) = date ? "#{date.month}/#{date.day}" : "-"

  # progress_rate は 0.0〜1.0 で保存されている(Notion の 70% → 0.7)
  def rate_line(previous_rate, current_rate)
    return "-" if previous_rate.nil? && current_rate.nil?
    return percent(current_rate) if previous_rate.nil? || percent(previous_rate) == percent(current_rate)
    "#{percent(previous_rate)} → #{percent(current_rate)}"
  end

  def percent(rate) = rate.nil? ? "-" : "#{(rate.to_f * 100).round}%"

  def text_line(previous_text, current_text)
    return current_text.to_s if previous_text.blank? || previous_text == current_text
    "#{previous_text} → #{current_text}"
  end
end
