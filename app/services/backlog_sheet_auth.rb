require "google/apis/sheets_v4"

# Backlog 対応ログのスプレッドシート入出力（エクスポート/インポート）で共有する、
# URL からの ID 抽出と「実際にアクセスできる管理者アカウント」の総当たり認証。
module BacklogSheetAuth
  S = Google::Apis::SheetsV4

  def extract_spreadsheet_id(url)
    url.to_s[%r{/spreadsheets/d/([a-zA-Z0-9_-]+)}, 1] or raise "スプレッドシートの URL が不正です"
  end

  # 対象シートに実際にアクセスできる管理者アカウントの service を返す（所有アカウントが分かれるため総当たり）。
  def authorized_sheets_service(spreadsheet_id, operator)
    candidates = User.where.not(google_refresh_token: [ nil, "" ]).select(&:admin?)
    candidates.unshift(operator) if GoogleAuth.has_token?(operator)
    candidates.uniq!
    candidates.each do |candidate|
      svc = S::SheetsService.new
      svc.authorization = GoogleAuth.build(candidate)
      svc.get_spreadsheet(spreadsheet_id, fields: "spreadsheetId")
      return svc
    rescue StandardError
      next
    end
    raise "このスプレッドシートにアクセスできる Google アカウントが見つかりません（西野さんのアカウントを編集者に）。"
  end
end
