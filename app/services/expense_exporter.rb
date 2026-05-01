require "fileutils"

# 立替金テンプレートに月次データを差し込む。XlsxFiller (openpyxl) 経由。
# 列マッピング (1-indexed): A=No B=日付 C=目的 D-H=交通機関 I=出発 J=～ K=到着 L=往復 M=領収書 N=金額 O=路線
# データ開始: Excel 12行目
class ExpenseExporter
  TEMPLATE = Rails.root.join("app/templates/expense_template.xlsx")

  HEADER_AUTHOR_ROW = 5
  HEADER_AUTHOR_COL = 14 # N5: 作成者（申請者本人）
  HEADER_ASSIGNEE_ROW = 7
  HEADER_ASSIGNEE_COL = 14 # N7: 担当者（発行者・admin）
  HEADER_PERIOD_ROW = 7
  HEADER_PERIOD_LABEL_COL = 1  # A
  HEADER_PERIOD_COL = 3  # C

  DATA_START_ROW = 12

  COL_NO       = 1
  COL_DATE     = 2
  COL_PURPOSE  = 3
  COL_TRAIN    = 4   # D
  COL_BUS      = 5
  COL_TAXI     = 6
  COL_SHINKAN  = 7
  COL_FLIGHT   = 8   # H
  COL_FROM     = 9   # I
  COL_TILDE    = 10
  COL_TO       = 11
  COL_ROUND    = 12
  COL_RECEIPT  = 13
  COL_AMOUNT   = 14
  COL_LINE     = 15

  TRANSPORT_COL = {
    "train"      => COL_TRAIN,
    "bus"        => COL_BUS,
    "taxi"       => COL_TAXI,
    "shinkansen" => COL_SHINKAN,
    "flight"     => COL_FLIGHT
  }.freeze

  def initialize(user, year:, month:, application_date: nil, category: nil,
                 client_name_override: nil, issuer_user_override: nil, merged_users: nil)
    @user = user
    @year = year
    @month = month
    @application_date = application_date
    @category = category.presence
    @client_name_override = client_name_override.presence
    @issuer_user = issuer_user_override || user
    # 集約モード: @user に加え @merged_users の expense もまとめる（案 A 通常立替金 1 通用）
    @merged_users = Array(merged_users).reject { |u| u.id == user.id }
  end

  DATA_END_ROW = 26 # テンプレのサンプルデータが入っている最終データ行

  def call
    cells = []
    # A4: 宛名 (override が指定されたらそちら、なければ申請者の会社名)
    a4_value = @client_name_override.presence || @user.company_name
    cells << { row: 4, col: 1, value: a4_value } if a4_value.present?
    # N5: 作成者 = 申請者本人（@user）
    # N7: 担当者 = 発行者（@issuer_user。例: 西野が川村のExcelを発行する場合は西野）
    author = @user.display_name
    cells << { row: HEADER_AUTHOR_ROW, col: HEADER_AUTHOR_COL, value: author } if author.present?
    assignee = @issuer_user.display_name
    cells << { row: HEADER_ASSIGNEE_ROW, col: HEADER_ASSIGNEE_COL, value: assignee } if assignee.present?
    period = @user.period_for(@year, @month)
    # 申請日: 発行者(issuer)の monthly_settings を優先（西野が川村の Excel を発行する場合は西野の末日設定を使う）
    app_date = @application_date || @issuer_user.application_date_for(@year, @month) || @user.application_date_for(@year, @month)
    cells << { row: HEADER_PERIOD_ROW, col: HEADER_PERIOD_LABEL_COL, value: "申請日" }
    cells << { row: HEADER_PERIOD_ROW, col: HEADER_PERIOD_COL, value: app_date.iso8601, type: "date" }

    # テンプレのサンプル行をまずクリア（書き込み前）
    (DATA_START_ROW..DATA_END_ROW).each do |row|
      (COL_NO..COL_LINE).each do |col|
        cells << { row: row, col: col, value: nil }
      end
    end

    # 集約モード: @user + @merged_users の expense をまとめる
    target_users = [ @user, *@merged_users ].uniq
    multi_user = target_users.size > 1
    user_expense_pairs = []
    target_users.each do |u|
      u_period = u.period_for(@year, @month)
      u_scope = u.expenses.in_range(u_period)
      u_scope = u_scope.where(category: @category) if @category
      u_scope = u_scope.where(company_burden: true) # 会社負担対象のみ
      u_scope.each { |e| user_expense_pairs << [ u, e ] }
    end

    user_expense_pairs.each_with_index do |(u, e), i|
      row = DATA_START_ROW + i

      cells << { row: row, col: COL_NO,      value: i + 1 }
      cells << { row: row, col: COL_DATE,    value: e.expense_date.iso8601, type: "date" }
      # 複数ユーザー集約時のみ purpose 先頭にユーザー名を付ける（行ごとに誰の expense か分かるように）
      purpose_text = if multi_user && u.display_name.present?
                       prefix = u.display_name.to_s.strip
                       e.purpose.to_s.start_with?(prefix) ? e.purpose.to_s : "[#{prefix}] #{e.purpose}"
      else
                       e.purpose
      end
      cells << { row: row, col: COL_PURPOSE, value: purpose_text }

      TRANSPORT_COL.each_value { |c| cells << { row: row, col: c, value: nil } }
      if (col = TRANSPORT_COL[e.transport_type])
        cells << { row: row, col: col, value: "○" }
      end

      cells << { row: row, col: COL_FROM,    value: e.from_station }
      cells << { row: row, col: COL_TILDE,   value: "～" }
      cells << { row: row, col: COL_TO,      value: e.to_station }
      cells << { row: row, col: COL_ROUND,   value: e.round_trip ? "✓" : nil }
      cells << { row: row, col: COL_RECEIPT, value: e.receipt_no.presence || "無" }
      cells << { row: row, col: COL_AMOUNT,  value: e.amount }
      cells << { row: row, col: COL_LINE,    value: e.payee_or_line }
    end

    out_dir = Rails.root.join("tmp/exports")
    out = out_dir.join("expense_#{@user.id}_#{@year}_#{@month}_#{SecureRandom.hex(4)}.xlsx").to_s
    sheet_name = "#{@year}年#{@month}月"
    XlsxFiller.call(template: TEMPLATE, output: out, sheet: 0, cells: cells, sheet_name: sheet_name)
    out
  end
end
