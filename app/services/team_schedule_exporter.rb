require "google/apis/sheets_v4"
require "signet/oauth_2/client"

# DB の team_schedules を Google スプレッドシートに書き戻す。
# シート構成は TeamScheduleImporter と同じ前提。
class TeamScheduleExporter
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

    person_columns = PERSONS.to_h do |person_name|
      column_index = header.each_with_index.find { |value, _| value.to_s.include?(person_name) }&.last
      [person_name, column_index ? column_index + 2 : nil]
    end

    schedules = TeamSchedule.where(year_month: sheet_title).index_by { |record| [record.person, record.date] }

    update_value_ranges = []
    person_columns.each do |person_name, status_column|
      next if status_column.nil?

      (2..rows.size - 1).each do |row_index|
        row = rows[row_index] || []
        day_value = row[status_column - 2].to_s.strip.to_i
        next if day_value.zero?

        date_value = begin
          Date.new(@year, @month, day_value)
        rescue ArgumentError
          next
        end

        record = schedules[[person_name, date_value]]
        next unless record

        column_letter = column_letter_for(status_column)
        cell_a1 = "#{sheet_title}!#{column_letter}#{row_index + 1}"
        update_value_ranges << Google::Apis::SheetsV4::ValueRange.new(
          range: cell_a1,
          values: [[record.status.to_s]]
        )
      end
    end

    return { sheet: sheet_title, updated: 0 } if update_value_ranges.empty?

    request = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(
      value_input_option: "USER_ENTERED",
      data: update_value_ranges
    )
    service.batch_update_values(spreadsheet_id, request)

    { sheet: sheet_title, updated: update_value_ranges.size }
  end

  private

  def extract_id(url)
    matched = url.match(%r{/spreadsheets/d/([a-zA-Z0-9_-]+)})
    raise "スプレッドシート URL が不正です" unless matched
    matched[1]
  end

  def column_letter_for(zero_based_index)
    index = zero_based_index
    letters = ""
    loop do
      letters = ((index % 26) + 65).chr + letters
      index = index / 26 - 1
      break if index < 0
    end
    letters
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
