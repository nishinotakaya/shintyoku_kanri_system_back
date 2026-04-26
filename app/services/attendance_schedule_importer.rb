require "google/apis/sheets_v4"
require "signet/oauth_2/client"

# 勤怠スケジュール Google スプレッドシートから、ユーザー本人の「休み」を抽出して返す。
# シート想定:
#   - シートタイトルは "YYYYMM" 形式（例: 202604）
#   - 2行目に人名ヘッダ（大隅 / 川村 / 土倉 / 西野 等）
#   - 各人 3 列占有（日 / 曜日 / ステータス）
#   - ステータスに「休み」と書かれている日をオフとして扱う
class AttendanceScheduleImporter
  def initialize(user:, year:, month:)
    @user = user
    @year = year
    @month = month
  end

  def call
    raise "勤怠スケジュール URL が未登録です" if @user.attendance_schedule_url.blank?
    raise "Google アクセストークンがありません。Google ログインしてください" if @user.google_access_token.blank?

    spreadsheet_id = extract_id(@user.attendance_schedule_url)
    surname = user_surname
    raise "ユーザー名が取得できません（display_name 未設定）" if surname.blank?

    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = build_auth

    spreadsheet = service.get_spreadsheet(spreadsheet_id)
    sheet_title = format("%04d%02d", @year, @month)
    sheet = spreadsheet.sheets.find { |s| s.properties.title == sheet_title }
    raise "対象シートが見つかりません: #{sheet_title}" unless sheet

    resp = service.get_spreadsheet_values(spreadsheet_id, "#{sheet_title}!A1:AZ50")
    rows = resp.values || []
    header = rows[1] || []

    # 姓が含まれる列を探す
    name_col = header.each_with_index.find { |v, _| v.to_s.include?(surname) }&.last
    raise "ヘッダに #{surname} が見つかりません" unless name_col

    status_col = name_col + 2

    off_days = []
    (2..rows.size - 1).each do |r|
      row = rows[r] || []
      day = row[name_col].to_s.strip.to_i
      next if day.zero?
      status = row[status_col].to_s.strip
      next unless status == "休み"
      begin
        off_days << Date.new(@year, @month, day).iso8601
      rescue ArgumentError
        next
      end
    end

    { sheet: sheet_title, surname: surname, off_days: off_days }
  end

  def call_and_apply
    result = call
    period_start = Date.new(@year, @month, 1)
    period_end = Date.new(@year, @month, -1)
    existing = Array(@user.custom_off_days).map(&:to_s)
    outside = existing.reject do |d|
      begin
        dt = Date.iso8601(d)
        dt >= period_start && dt <= period_end
      rescue ArgumentError
        false
      end
    end
    merged = (outside + result[:off_days]).uniq.sort
    @user.update!(custom_off_days: merged)
    result.merge(custom_off_days: merged)
  end

  private

  def extract_id(url)
    m = url.match(%r{/spreadsheets/d/([a-zA-Z0-9_-]+)})
    raise "スプレッドシート URL が不正です" unless m
    m[1]
  end

  def user_surname
    @user.display_name.to_s.split(/[\s　]/).first
  end

  def build_auth
    auth = Signet::OAuth2::Client.new(
      token_credential_uri: "https://oauth2.googleapis.com/token",
      client_id: ENV["GOOGLE_CLIENT_ID"],
      client_secret: ENV["GOOGLE_CLIENT_SECRET"],
      access_token: @user.google_access_token,
      refresh_token: @user.google_refresh_token
    )
    if @user.google_token_expires_at.nil? || @user.google_token_expires_at < Time.current
      if @user.google_refresh_token.present?
        auth.fetch_access_token!
        @user.update!(google_access_token: auth.access_token, google_token_expires_at: Time.current + 3600)
      end
    end
    auth
  end
end
