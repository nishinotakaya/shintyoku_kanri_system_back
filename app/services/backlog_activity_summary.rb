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

  # 上司報告サマリの行（課題ごとに1行・最新月に集約／最新月が新しい順）。
  # 同じ課題が複数月にまたがっても内容は同じなので、一番新しい月の1行だけを出す
  # (例: SAP-4057 が 2026-06/2026-07 にあれば 2026-07 の1行)。概要/状態/開始日/処理済日/完了日は
  # その課題の全活動から算出するので、月をまとめても情報は失われない。
  # 活動が無い「備考だけの行」（例: Notion ドキュメントハブの資料リンク集）も末尾に出す。
  def rows
    @rows ||= issue_rows + note_only_rows
  end

  def issue_url(issue_key)
    return nil if @backlog_url.blank?
    "#{@backlog_url}/view/#{issue_key}"
  end

  private

  # 課題ごと1行(最新月)の本体行。
  def issue_rows
    latest_month_by_issue.map do |issue_key, month|
      info = issue_data.fetch(issue_key)
      note = note_for(issue_key, month)
      # 完了日が確定していれば「完了」を正とする(状態変更の活動ログが同期範囲外で
      # 拾えていなくても、リリース済という事実を「処理済み」のまま残さない)。
      done_date = completions[issue_key]&.completed_on || info[:done]
      computed_status = done_date.present? ? STATUS_DONE : info[:status]
      {
        month:           month,
        issue_key:       issue_key,
        summary:         info[:summary],
        # 完了(リリース済)は Backlog の事実なので手入力 override より優先する。それ以外は override が勝つ。
        status:          computed_status == STATUS_DONE ? STATUS_DONE : (note&.status_override.presence || computed_status),
        computed_status: computed_status,
        status_override: note&.status_override.to_s,
        start_on:        d(info[:start]),
        shori_on:        d(info[:shori]),
        done_on:         d(done_date),
        note:            note&.note.to_s,
        notion_block_id: note&.notion_block_id.to_s,
        url:             issue_url(issue_key)
      }
    end
  end

  # 活動に紐づかない備考行（課題キーに activities が1件も無い BacklogSummaryNote）。
  # Notion ドキュメントハブの資料リンク集(「資料:○○」行)などがここに出る。
  # 集約後は「課題単位」で活動有無を見る(活動のある課題の古い月メモは note_for で吸収する)。
  def note_only_rows
    active_issue_keys = latest_month_by_issue.keys.to_set
    notes.filter_map do |(month, issue_key), note|
      next if active_issue_keys.include?(issue_key)
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

  # 課題ごとの最新月（月が新しい順に並べる。同月内は課題キー降順）。
  def latest_month_by_issue
    @latest_month_by_issue ||= activities.group_by(&:issue_key)
      .transform_values { |acts| acts.map(&:month).compact.max }
      .sort_by { |issue_key, month| [ month.to_s, issue_key.to_s ] }
      .reverse
      .to_h
  end

  # 集約後の行に載せるメモ。最新月にメモ/上書きがあればそれを、無ければ同じ課題の
  # 別の月で内容のあるメモのうち最新のものを使う(古い月のメモを取りこぼさない)。
  def note_for(issue_key, month)
    direct = notes[[ month, issue_key ]]
    return direct if direct && (direct.note.present? || direct.status_override.present?)
    fallback = notes_by_issue[issue_key]
      &.select { |note| note.note.present? || note.status_override.present? }
      &.max_by { |note| note.month.to_s }
    fallback || direct
  end

  def activities
    @activities ||= @user.backlog_activities.order(:occurred_on, :activity_id).to_a
  end

  def notes
    @notes ||= @user.backlog_summary_notes.index_by { |n| [ n.month, n.issue_key ] }
  end

  def notes_by_issue
    @notes_by_issue ||= @user.backlog_summary_notes.group_by(&:issue_key)
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

  def d(date) = date ? date.to_s : ""
end
