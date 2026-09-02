# LINE 進捗報告の送信文面(NotionLineReport / フロント lib/notionLineReport.ts と同じ書式)を
# タスク単位の構造化データに戻すパーサ。ユーザーがモーダルで文面を編集していても、
# ラベル行(タスク:/開始日: など)が残っていれば拾える。
#
#   📋 進捗報告（西野）
#
#   タスク: 見積書 2.2.7.3.5
#   開始日: 2026/09/10 → 9/15
#   終了日: 2026/09/22
#   進捗率: 70% → 90%
#   ステータス: 処理中 → 処理済
#   備考(遅れた理由など): 仕様追加のため
#   リンク
#   https://www.notion.so/...
class LineReportMessageParser
  FIELD_PATTERNS = {
    start_date_text: /\A開始日[:：]\s*(.*)\z/,
    end_date_text:   /\A終了日[:：]\s*(.*)\z/,
    progress_text:   /\A進捗率[:：]\s*(.*)\z/,
    status_text:     /\A(?:ステータス|状態)[:：]\s*(.*)\z/,
    note:            /\A備考(?:（.*?）|\(.*?\))?[:：]\s*(.*)\z/
  }.freeze
  TASK_PATTERN = /\Aタスク[:：]\s*(.*)\z/
  LINK_LABEL_PATTERN = /\Aリンク\z/
  URL_PATTERN = %r{\Ahttps?://\S+\z}

  # => [ { task_title:, start_date_text:, end_date_text:, progress_text:, status_text:, note:, url: }, ... ]
  def self.parse(message)
    entries = []
    current = nil
    expecting_url = false

    message.to_s.each_line(chomp: true) do |line|
      line = line.strip
      next if line.empty?

      if (task_match = line.match(TASK_PATTERN))
        current = { task_title: task_match[1].strip }
        entries << current unless task_match[1].strip.empty?
        expecting_url = false
        next
      end
      next unless current

      if line.match?(LINK_LABEL_PATTERN)
        expecting_url = true
        next
      end
      if expecting_url && line.match?(URL_PATTERN)
        current[:url] = line
        expecting_url = false
        next
      end

      matched_field = FIELD_PATTERNS.find { |_, pattern| line.match?(pattern) }
      if matched_field
        field_name, pattern = matched_field
        value = line.match(pattern)[1].strip
        current[field_name] = value.presence
        expecting_url = false
      elsif current.key?(:note) && !expecting_url
        # 備考が複数行のとき(テキストエリア入力)は続きの行として結合する
        current[:note] = [ current[:note], line ].compact.join("\n")
      end
    end

    entries
  end
end
