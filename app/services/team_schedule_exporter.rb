require "google/apis/sheets_v4"
require "signet/oauth_2/client"

# DB の team_schedules を Google スプレッドシートに書き戻す。
# シート構成は TeamScheduleImporter と同じ前提。対象者はヘッダから動的検出。
class TeamScheduleExporter
  include TeamScheduleSheetPersons

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
    # 対象月のシートが無ければ、直近の月シートを複製して同じレイアウトで自動作成する
    sheet ||= create_month_sheet(service, spreadsheet_id, spreadsheet, sheet_title)

    response = service.get_spreadsheet_values(spreadsheet_id, "#{sheet_title}!A1:AZ50")
    rows = response.values || []

    person_columns = detect_person_columns(rows)

    schedules = TeamSchedule.where(year_month: sheet_title).index_by { |record| [ record.person, record.date ] }

    update_value_ranges = []
    person_columns.each do |person_name, status_column|
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

  # 対象月のシートが無いとき、直近の既存月シートを複製して同じレイアウトで作成する。
  # 複製後にタイトル行と全トリオ(日/曜)を対象月の日付へ書き換え、ステータス列は空にする。
  # 祝日などの凡例列の名前は手入力運用のため空のまま(レイアウト・書式は複製で引き継がれる)
  def create_month_sheet(service, spreadsheet_id, spreadsheet, sheet_title)
    template = latest_month_sheet_before(spreadsheet, sheet_title)
    raise "対象シートが見つかりません: #{sheet_title}（複製元になる月シートもありません）" unless template

    duplicate_request = Google::Apis::SheetsV4::Request.new(
      duplicate_sheet: Google::Apis::SheetsV4::DuplicateSheetRequest.new(
        source_sheet_id: template.properties.sheet_id,
        new_sheet_name: sheet_title,
        insert_sheet_index: spreadsheet.sheets.size
      )
    )
    reply = service.batch_update_spreadsheet(
      spreadsheet_id,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: [ duplicate_request ])
    )
    new_sheet_properties = reply.replies.first.duplicate_sheet.properties

    write_month_skeleton(service, spreadsheet_id, template, sheet_title)

    Google::Apis::SheetsV4::Sheet.new(properties: new_sheet_properties)
  end

  # 「YYYYMM」名のシートのうち、対象より前で最も新しいものを複製元にする(無ければ全体で最新)
  def latest_month_sheet_before(spreadsheet, sheet_title)
    month_sheets = spreadsheet.sheets.select { |candidate| candidate.properties.title.match?(/\A\d{6}\z/) }
    earlier_sheets = month_sheets.select { |candidate| candidate.properties.title < sheet_title }
    (earlier_sheets.presence || month_sheets).max_by { |candidate| candidate.properties.title }
  end

  # 複製したシートの中身を対象月に書き換える。
  # - タイトル行(B1): 「YYYY年M月作業予定」
  # - 全トリオ(人物・凡例とも): 日番号と曜日を対象月で書き直し、ステータスは空にする
  def write_month_skeleton(service, spreadsheet_id, template, sheet_title)
    year = sheet_title[0, 4].to_i
    month = sheet_title[4, 2].to_i

    template_rows = service.get_spreadsheet_values(spreadsheet_id, "#{template.properties.title}!A1:AZ50").values || []
    day_columns = detect_day_columns(template_rows)

    data = [ Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!B1", values: [ [ "#{year}年#{month}月作業予定" ] ]) ]
    day_columns.each do |day_column|
      from_letter = column_letter_for(day_column)
      to_letter = column_letter_for(day_column + 2)
      data << Google::Apis::SheetsV4::ValueRange.new(
        range: "#{sheet_title}!#{from_letter}3:#{to_letter}33",
        values: month_day_rows(year, month)
      )
    end
    service.batch_update_values(
      spreadsheet_id,
      Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(value_input_option: "USER_ENTERED", data: data)
    )
  end

  # 対象月の [日番号, 曜日, ステータス(空)] を31行分。月の日数を超える行は空にする
  def month_day_rows(year, month)
    days_in_month = Date.new(year, month, -1).day
    weekday_kanji = %w[日 月 火 水 木 金 土]
    (1..31).map do |day|
      if day <= days_in_month
        [ day, weekday_kanji[Date.new(year, month, day).wday], "" ]
      else
        [ "", "", "" ]
      end
    end
  end

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
