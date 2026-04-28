require "google/apis/sheets_v4"
require "signet/oauth_2/client"

# 勤怠スケジュール Google スプレッドシートから複数人（大隅 / 川村 / 西野）のステータスを取り込む。
# 既存の AttendanceScheduleImporter は単一ユーザー（自分の休み）専用なので分離。
#
# シート構成:
#   - シート名 "YYYYMM"
#   - 2行目に人名ヘッダ。各人 3 列占有（日 / 曜 / ステータス）
#   - ステータス例: "出社", "リモート", "リビング リモート", "休み", "高田馬場" 等
class TeamScheduleImporter
  PERSONS = %w[大隅 川村 西野].freeze

  def initialize(user:, year:, month:)
    @user = user
    @year = year
    @month = month
  end

  def call
    raise "勤怠スケジュール URL が未登録です" if @user.attendance_schedule_url.blank?
    raise "Google アクセストークンがありません。Google ログインしてください" if @user.google_access_token.blank?

    spreadsheet_id = extract_id(@user.attendance_schedule_url)
    sheet_title = format("%04d%02d", @year, @month)

    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = build_auth

    spreadsheet = service.get_spreadsheet(spreadsheet_id)
    sheet = spreadsheet.sheets.find { |target| target.properties.title == sheet_title }
    raise "対象シートが見つかりません: #{sheet_title}" unless sheet

    response = service.get_spreadsheet_values(spreadsheet_id, "#{sheet_title}!A1:AZ50")
    rows = response.values || []
    header = rows[1] || []

    # 人名 → ステータス列のマッピング
    person_columns = PERSONS.to_h do |person_name|
      column_index = header.each_with_index.find { |value, _| value.to_s.include?(person_name) }&.last
      [ person_name, column_index ? column_index + 2 : nil ]
    end

    imported = 0
    # 集計用: { person => { wings:, living: } }
    totals = PERSONS.to_h { |person_name| [ person_name, { wings: 0.0, living: 0.0 } ] }

    person_columns.each do |person_name, status_column|
      next if status_column.nil?

      (2..rows.size - 1).each do |row_index|
        row = rows[row_index] || []
        # day 列（status 列 - 2）
        day_value = row[status_column - 2].to_s.strip.to_i
        next if day_value.zero?
        status_value = row[status_column].to_s.strip
        next if status_value.empty?

        date_value = begin
          Date.new(@year, @month, day_value)
        rescue ArgumentError
          next
        end

        normalized = normalize_status(status_value)
        record = TeamSchedule.find_or_initialize_by(date: date_value, person: person_name)
        record.assign_attributes(status: normalized, year_month: sheet_title)
        record.save!
        imported += 1

        eh = expected_hours(normalized)
        totals[person_name][:wings]  += eh[:wings]
        totals[person_name][:living] += eh[:living]
      end
    end

    write_totals_back(service, spreadsheet_id, sheet_title, person_columns, totals)

    { sheet: sheet_title, imported: imported, persons: PERSONS }
  end

  private

  # シートに合計を書き戻す（A34=T合計、A35=L合計、各人の status 列 row34/35 に値）
  def write_totals_back(service, spreadsheet_id, sheet_title, person_columns, totals)
    data = [
      Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!A34", values: [ [ "T合計" ] ]),
      Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!A35", values: [ [ "L合計" ] ])
    ]
    person_columns.each do |person_name, status_col|
      next if status_col.nil?
      letter = column_letter(status_col)
      t = totals[person_name]
      data << Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!#{letter}34", values: [ [ t[:wings] ] ])
      data << Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!#{letter}35", values: [ [ t[:living] ] ])
    end
    request = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(
      value_input_option: "USER_ENTERED",
      data: data
    )
    service.batch_update_values(spreadsheet_id, request)
  end

  # ステータス → wings/living 推計時間（CalendarView.expectedHours と同じロジック）
  def expected_hours(status)
    s = status.to_s
    return { wings: 0.0, living: 0.0 } if s.blank? || s.include?("休み") || s.include?("定休")
    return { wings: 3.5, living: 5.0 } if s.include?("午前") && s.include?("リビング")
    return { wings: 3.5, living: 5.0 } if s.include?("リビング") && s =~ %r{[/／]}
    return { wings: 0.0, living: 8.0 } if s.include?("リビング")
    { wings: 8.0, living: 0.0 }
  end

  # 0-indexed 列番号 → A1 形式の列文字（0→A, 25→Z, 26→AA）
  def column_letter(zero_indexed_col)
    n = zero_indexed_col + 1
    letters = ""
    while n > 0
      n -= 1
      letters = (("A".ord + n % 26).chr) + letters
      n /= 26
    end
    letters
  end

  # 改行・前後空白を除去するのみ（TL@ プレフィクスや括弧補足は保持）
  def normalize_status(value)
    value.to_s.gsub(/\r/, "").gsub(/\n+/, " ").strip
  end

  def extract_id(url)
    matched = url.match(%r{/spreadsheets/d/([a-zA-Z0-9_-]+)})
    raise "スプレッドシート URL が不正です" unless matched
    matched[1]
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
