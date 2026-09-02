# LINE 送信済みの進捗報告を記録する入口。
# 文面をパースして line_report_entries に upsert(同じ日付×同じタスクは上書き)し、
# 当月の Google スプレッドシート(進捗管理表)タブを再生成する。
# シート側の失敗は LINE 送信自体の成否に影響させない(warning としてログと戻り値に残す)。
module LineReportArchiver
  module_function

  def record(user:, message:, reported_on: Time.zone.today)
    parsed_entries = LineReportMessageParser.parse(message)
    return { archived: 0, sheet_synced: false } if parsed_entries.empty?

    parsed_entries.each do |attrs|
      entry = LineReportEntry.find_or_initialize_by(
        user_id: user.id, reported_on: reported_on, task_title: attrs[:task_title]
      )
      entry.update!(attrs.except(:task_title))
    end

    begin
      LineReportSheetSync.sync(operator: user, month: reported_on)
      { archived: parsed_entries.size, sheet_synced: true }
    rescue StandardError => e
      Rails.logger.error("[LineReportArchiver] sheet sync failed: #{e.class}: #{e.message}")
      { archived: parsed_entries.size, sheet_synced: false, sheet_error: e.message }
    end
  end
end
