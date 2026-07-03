require "google/apis/sheets_v4"

# 上司報告用サマリ（スプレッドシート先頭タブ gid=0）の手入力＝状態推移・備考を、アプリの
# BacklogSummaryNote に取り込む。Backlog から自動算出する 月/課題/概要/開始日/処理済日/完了日
# は対象外。空セルでアプリの値を消さない（非破壊）。
class BacklogActivityImporter
  include BacklogSheetAuth

  COL_MONTH  = 0
  COL_ISSUE  = 1
  COL_STATUS = 3  # 状態推移
  COL_NOTE   = 7  # 備考

  def initialize(user:, operator:, spreadsheet_url:)
    @user = user
    @operator = operator
    @spreadsheet_id = extract_spreadsheet_id(spreadsheet_url)
  end

  def call
    service = authorized_sheets_service(@spreadsheet_id, @operator)
    spreadsheet = service.get_spreadsheet(@spreadsheet_id, fields: "sheets.properties")
    summary_tab = spreadsheet.sheets.first.properties.title # 先頭タブ(gid=0)
    rows = service.get_spreadsheet_values(@spreadsheet_id, "#{summary_tab}!A1:H1000").values || []
    header_idx = rows.index { |r| Array(r).include?("課題") }
    raise "サマリシートに『課題』ヘッダが見つかりません（テンプレートを確認してください）。" unless header_idx

    imported = 0
    (header_idx + 1...rows.size).each do |i|
      row = rows[i] || []
      issue_key = row[COL_ISSUE].to_s[/[A-Z]+-\d+/]
      month = row[COL_MONTH].to_s.strip
      next if issue_key.blank? || month.blank?

      status = row[COL_STATUS].to_s.strip
      note   = row[COL_NOTE].to_s.strip
      next if status.blank? && note.blank?

      record = @user.backlog_summary_notes.find_or_initialize_by(month: month, issue_key: issue_key)
      record.status_override = status if status.present?
      record.note = note if note.present?
      next unless record.changed?

      record.save!
      imported += 1
    end

    { imported_rows: imported, url: "https://docs.google.com/spreadsheets/d/#{@spreadsheet_id}/edit" }
  rescue Google::Apis::ClientError => e
    raise "スプレッドシートの読み取りに失敗しました（権限を確認してください）: #{e.message}"
  end
end
