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
    # URL/トークンが無いユーザー (川村など) は admin (西野) の認証情報にフォールバック
    @credentials_user = pick_credentials_user(user)
  end

  def call
    raise "勤怠スケジュール URL が未登録です（管理者の Google 連携が必要）" if @credentials_user.attendance_schedule_url.blank?
    raise "Google アクセストークンがありません" if @credentials_user.google_access_token.blank?

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

    # 人名 → ステータス列のマッピング
    person_columns = PERSONS.to_h do |person_name|
      column_index = header.each_with_index.find { |value, _| value.to_s.include?(person_name) }&.last
      [ person_name, column_index ? column_index + 2 : nil ]
    end

    imported = 0
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

        record = TeamSchedule.find_or_initialize_by(date: date_value, person: person_name)
        record.assign_attributes(status: normalize_status(status_value), year_month: sheet_title)
        record.save!
        imported += 1
      end
    end

    write_totals_back(service, spreadsheet_id, sheet_title, person_columns)

    # 出社予定の日に交通費を自動作成（取り込んだ team_schedule に基づく）
    expenses_created = sync_commute_expenses

    { sheet: sheet_title, imported: imported, persons: PERSONS, expenses_created: expenses_created }
  end

  # team_schedules の status が "出社" の日に、display_name でマッチするユーザーごとの
  # default_transit_* で Expense を自動作成する。
  def sync_commute_expenses
    total = 0
    PERSONS.each do |person_name|
      target = User.where("display_name LIKE ?", "%#{person_name}%").find_each.find { |u| !u.display_name.to_s.start_with?("wing") }
      next unless target
      created = TeamScheduleExpenseSync.new(user: target, year: @year, month: @month).call
      total += created.size
    end
    total
  rescue => e
    Rails.logger.warn("[TeamScheduleImporter] sync_commute_expenses error: #{e.class}: #{e.message}")
    0
  end

  private

  # 共有シート操作のため、admin (西野) を優先。admin の token は spreadsheets スコープあり前提
  def pick_credentials_user(user)
    admin = User.where("display_name LIKE ?", "%西野%").find do |candidate|
      candidate.attendance_schedule_url.present? && candidate.google_access_token.present?
    end
    admin || user
  end

  # シートに合計関数を書き戻す。A34="T合計", A35="L合計" + 西野(M)/川村(G) の row34/35 に
  # 締日基準（カレンダーの period_for と同じ）で COUNTIF 式を書く。
  # 例: closing_day=25, year=2026, month=5 → 期間 4/26〜5/25
  #   - 4月シート (202604) の row28〜row32 (4/26〜4/30)
  #   - 5月シート (202605) の row3〜row27 (5/1〜5/25)
  def write_totals_back(service, spreadsheet_id, sheet_title, person_columns)
    period = @user.period_for(@year, @month)
    from_d = period.first
    to_d = period.last

    curr_first_row = (from_d.year == @year && from_d.month == @month) ? from_d.day + 2 : 3
    curr_last_row  = to_d.day + 2  # to は必ず当月内

    prev_sheet = nil
    prev_first_row = nil
    prev_last_row = nil
    if from_d.month != @month || from_d.year != @year
      prev_sheet     = format("%04d%02d", from_d.year, from_d.month)
      prev_first_row = from_d.day + 2
      prev_last_row  = Date.new(from_d.year, from_d.month, -1).day + 2
    end

    data = [
      Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!A34", values: [ [ "T合計" ] ]),
      Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!A35", values: [ [ "L合計" ] ])
    ]

    # 西野・川村は formula、それ以外（大隅・土倉等）は空にする
    target_persons = %w[西野 川村]
    person_columns.each do |person, status_col|
      next if status_col.nil?
      letter = column_letter(status_col)
      if target_persons.include?(person)
        curr_range = "#{letter}#{curr_first_row}:#{letter}#{curr_last_row}"
        prev_range = prev_sheet ? "'#{prev_sheet}'!#{letter}#{prev_first_row}:#{letter}#{prev_last_row}" : nil
        ranges = [ curr_range, prev_range ].compact

        # 「午前タマ/午後リビング」= タマ3h + リビング5h
        # その他リビング含 = リビング 8h
        # 休み/定休 = 0、それ以外 = タマ 8h
        # T合計 = (純粋タマ日 × 8) + (午前タマ午後リビング日 × 3)
        # L合計 = (純粋リビング日 × 8) + (午前タマ午後リビング日 × 5)
        split_pat = "*午前タマ*午後リビング*"
        tama_terms = ranges.map do |r|
          # 純粋タマ = 全 - リビング含 - 休み - 定休（午前タマ/午後リビング はリビング含に入るのでこれで除外済み）
          "(COUNTA(#{r}) - COUNTIF(#{r},\"*リビング*\") - COUNTIF(#{r},\"*休み*\") - COUNTIF(#{r},\"*定休*\")) * 8 + COUNTIF(#{r},\"#{split_pat}\") * 3"
        end
        living_terms = ranges.map do |r|
          # 純粋リビング日 = リビング含 - 午前タマ午後リビング → ×8、 split → ×5
          "(COUNTIF(#{r},\"*リビング*\") - COUNTIF(#{r},\"#{split_pat}\")) * 8 + COUNTIF(#{r},\"#{split_pat}\") * 5"
        end
        tama_formula = "=" + tama_terms.join(" + ")
        living_formula = "=" + living_terms.join(" + ")

        data << Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!#{letter}34", values: [ [ tama_formula ] ])
        data << Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!#{letter}35", values: [ [ living_formula ] ])
      else
        # 対象外は空文字で上書き（古い値が残らないように）
        data << Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!#{letter}34", values: [ [ "" ] ])
        data << Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet_title}!#{letter}35", values: [ [ "" ] ])
      end
    end

    request = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(
      value_input_option: "USER_ENTERED",
      data: data
    )
    service.batch_update_values(spreadsheet_id, request)
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
