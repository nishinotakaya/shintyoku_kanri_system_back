# 上司報告サマリ(スプレッドシート先頭タブ)を、アプリの現行サマリ(BacklogActivitySummary)に
# 突き合わせて「削除すべき古い行」を判定する純粋なクエリオブジェクト。
#
# 背景: エクスポートは非破壊なので、過去の同期で書かれた 月×課題 行がアプリから消えても
# シートに残り続ける(例: 川村が実際には活動していない月に SAP-3662 が並ぶ=重複に見える)。
# これを解消するため、エクスポート後に「対象ユーザー本人の担当で、かつ現行サマリに無い行」だけを
# 削除する。シートは複数人(西野/川村ほか)の行が同居するので、他者の行・資料行は絶対に消さない。
#
# Google Sheets API に触らず行データだけで判定できるよう独立させ、単体テストの対象にする。
class BacklogSummarySheetReconciler
  COL_MONTH    = 0
  COL_ISSUE    = 1
  COL_ASSIGNEE = 8 # 担当者(末尾列)。対象ユーザー本人の行だけを削除対象にするための識別子。

  ISSUE_KEY_RE = /[A-Z]+-\d+/

  # sheet_rows    … シート先頭タブの全行(FORMATTED値の二次元配列)
  # header_index  … 「課題」ヘッダ行の 0-based index
  # app_pairs     … アプリ現行サマリの [month, issue_key] 一覧(これに含まれる行は残す)
  # target_name   … 対象ユーザーの表示名(担当者列がこの人と一致する行だけ削除する)
  def initialize(sheet_rows:, header_index:, app_pairs:, target_name:)
    @sheet_rows = sheet_rows
    @header_index = header_index
    @app_pairs = app_pairs.map { |month, issue_key| [ month.to_s, issue_key.to_s ] }.to_set
    @target_name = normalize(target_name)
  end

  # 削除すべきシート行の 0-based row index。降順(大きい方が先)で返す。
  # 降順なのは、上から順に消すと下の行 index がずれるため。DeleteDimension を降順に適用すれば安全。
  def stale_row_indices
    return [] if @target_name.blank?

    indices = ((@header_index + 1)...@sheet_rows.size).select do |row_index|
      row = @sheet_rows[row_index] || []
      issue_key = row[COL_ISSUE].to_s[ISSUE_KEY_RE]
      next false if issue_key.blank?                         # 資料:行など課題キー無しは対象外(温存)
      month = row[COL_MONTH].to_s.strip
      next false if @app_pairs.include?([ month, issue_key ]) # アプリ現行サマリにある=正しい行なので残す
      normalize(row[COL_ASSIGNEE]) == @target_name           # 担当者が対象ユーザー本人の行だけ削除
    end
    indices.sort.reverse
  end

  private

  # 担当者名の突合はスペース有無を無視する("川村 卓也"(表示名) と "川村卓也"(Backlog実担当) を同一視)。
  def normalize(name) = name.to_s.gsub(/\s/, "")
end
