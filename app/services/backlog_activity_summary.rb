# Backlog 活動(BacklogActivity)から「上司報告用サマリ」の行を組み立てる単一の窓口。
# 月×課題 単位で 概要 / 状態推移 / 開始日 / 処理済日 / 完了日 を活動から自動算出し、
# 手入力の 備考 / 状態上書き (BacklogSummaryNote) をマージする。
#
# API(コントローラ)・エクスポーター・インポーターが同じ行定義を共有し、表記がぶれないようにする。
class BacklogActivitySummary
  STATUS_DONE  = "完了".freeze
  STATUS_SHORI = "処理済み".freeze

  # 状態推移の凡例（テンプレート先頭行と同じ）。フロントの説明表示にも使う。
  STATUS_LEGEND = [
    "処理中 → 対応中",
    "処理済 → テストまで完了(レビュー待ち/西野が追加依頼対応など)",
    "完了 → リリース済"
  ].freeze

  def initialize(user)
    @user = user
    @backlog_url = user.backlog_setting&.backlog_url.to_s.chomp("/")
  end

  # 上司報告サマリの行（月×課題の出現順）。
  # 活動が無い「備考だけの行」（例: Notion ドキュメントハブの資料リンク集）も末尾に出す。
  def rows
    @rows ||= month_issue_pairs.map do |month, issue_key|
      info = issue_data.fetch(issue_key)
      note = notes[[ month, issue_key ]]
      computed_status = info[:status]
      {
        month:           month,
        issue_key:       issue_key,
        summary:         info[:summary],
        status:          note&.status_override.presence || computed_status,
        computed_status: computed_status,
        status_override: note&.status_override.to_s,
        start_on:        d(info[:start]),
        shori_on:        d(info[:shori]),
        done_on:         d(completions[issue_key]&.completed_on || info[:done]),
        note:            note&.note.to_s,
        notion_block_id: note&.notion_block_id.to_s,
        url:             issue_url(issue_key)
      }
    end + note_only_rows
  end

  def issue_url(issue_key)
    return nil if @backlog_url.blank?
    "#{@backlog_url}/view/#{issue_key}"
  end

  private

  # 活動に紐づかない備考行（月×キーが activities に存在しない BacklogSummaryNote）。
  # Notion ドキュメントハブの資料リンク集(「資料:○○」行)などがここに出る。
  def note_only_rows
    existing = month_issue_pairs
    notes.filter_map do |(month, issue_key), note|
      next if existing.include?([ month, issue_key ])
      next if note.note.blank?
      {
        month: month, issue_key: issue_key,
        summary: "", status: note.status_override.to_s, computed_status: "",
        status_override: note.status_override.to_s,
        start_on: "", shori_on: "", done_on: "",
        note: note.note.to_s, notion_block_id: note.notion_block_id.to_s,
        url: nil
      }
    end.sort_by { |row| [ row[:month].to_s, row[:issue_key].to_s ] }
  end

  def activities
    @activities ||= @user.backlog_activities.order(:occurred_on, :activity_id).to_a
  end

  def notes
    @notes ||= @user.backlog_summary_notes.index_by { |n| [ n.month, n.issue_key ] }
  end

  # 課題ごとの完了日（Backlog の changeLog から同期した値）。done_on の優先ソース。
  def completions
    @completions ||= @user.backlog_completions.index_by(&:issue_key)
  end

  # 課題ごとの派生データ（状態 / 開始 / 処理済 / 完了 / 概要）
  def issue_data
    @issue_data ||= activities.group_by(&:issue_key).transform_values do |acts|
      status_acts = acts.select { |a| a.activity_type == "status" }
                        .sort_by { |a| [ a.occurred_on.to_s, a.activity_id ] }
      after = ->(a) { a.content.to_s.split("→").last.to_s.strip }
      {
        summary: acts.map(&:summary).compact.first.to_s,
        status:  status_acts.map { |a| after.call(a) }.last.to_s,
        start:   acts.map(&:occurred_on).compact.min,
        shori:   status_acts.find { |a| after.call(a) == STATUS_SHORI }&.occurred_on,
        done:    status_acts.find { |a| after.call(a) == STATUS_DONE }&.occurred_on
      }
    end
  end

  # 月×課題 の組み合わせ（月・課題キー順）
  def month_issue_pairs
    activities.group_by { |a| [ a.month, a.issue_key ] }.keys
              .sort_by { |month, issue_key| [ month.to_s, issue_key.to_s ] }
  end

  def d(date) = date ? date.to_s : ""
end
