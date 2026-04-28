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
    # URL/トークンが無いユーザー (川村など) は admin (西野) の認証情報にフォールバック
    @credentials_user = pick_credentials_user(user)
    # 大隅は書き戻し不可。admin (西野) は全員、それ以外は自分の苗字の行のみ
    @restrict_to_persons = if user.admin?
      nil
    elsif user.display_name.to_s.include?("大隅")
      raise "大隅ユーザーは書き戻しできません"
    else
      [ user.display_name.to_s.split(/[\s　]/).first ].compact_blank
    end
  end

  def call
    raise "勤怠スケジュール URL が未登録です" if @credentials_user.attendance_schedule_url.blank?
    raise "Google アクセストークンがありません。Google ログインしてください" if @credentials_user.google_access_token.blank?

    spreadsheet_id = extract_id(@credentials_user.attendance_schedule_url)
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
      [ person_name, column_index ? column_index + 2 : nil ]
    end

    schedules = TeamSchedule.where(year_month: sheet_title).index_by { |record| [ record.person, record.date ] }

    update_value_ranges = []
    person_columns.each do |person_name, status_column|
      next if status_column.nil?
      # 制限ユーザーは指定された人物の行のみ
      next if @restrict_to_persons && !@restrict_to_persons.any? { |p| person_name.include?(p) || p.include?(person_name) }

      (2..rows.size - 1).each do |row_index|
        row = rows[row_index] || []
        day_value = row[status_column - 2].to_s.strip.to_i
        next if day_value.zero?

        date_value = begin
          Date.new(@year, @month, day_value)
        rescue ArgumentError
          next
        end

        record = schedules[[ person_name, date_value ]]
        next unless record

        column_letter = column_letter_for(status_column)
        cell_a1 = "#{sheet_title}!#{column_letter}#{row_index + 1}"
        update_value_ranges << Google::Apis::SheetsV4::ValueRange.new(
          range: cell_a1,
          values: [ [ record.status.to_s ] ]
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

  def pick_credentials_user(user)
    admin = User.where("display_name LIKE ?", "%西野%").find do |candidate|
      candidate.attendance_schedule_url.present? && candidate.google_access_token.present?
    end
    admin || user
  end

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
    cu = @credentials_user
    auth = Signet::OAuth2::Client.new(
      token_credential_uri: "https://oauth2.googleapis.com/token",
      client_id: ENV["GOOGLE_CLIENT_ID"],
      client_secret: ENV["GOOGLE_CLIENT_SECRET"],
      access_token: cu.google_access_token,
      refresh_token: cu.google_refresh_token
    )
    if cu.google_token_expires_at.nil? || cu.google_token_expires_at < Time.current
      if cu.google_refresh_token.present?
        auth.fetch_access_token!
        cu.update!(google_access_token: auth.access_token, google_token_expires_at: Time.current + 3600)
      end
    end
    auth
  end
end
