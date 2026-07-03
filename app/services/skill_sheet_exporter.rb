require "google/apis/sheets_v4"

# DB のスキルシート構造化データを「見本シート」と全く同じレイアウトで Google スプレッドシートに書き戻す。
#   見本: https://docs.google.com/spreadsheets/d/18ijrplSv1HA2ou1wsgs_qBAg_93pyXsfu-W5muXzUto/edit
#
# レイアウト (0-indexed):
#   row0  スキルシート (タイトル, A:Q 結合)
#   row1  技術者名 | 値(C:Q)        ← 上部は全て「ラベル A:B + 値 C:Q」の縦1列
#   row2  年齢 | 値(C:Q)
#   row3  稼動開始 | 値(C:Q)
#   row4  性別 | 値(C:Q)            ← 稼動開始の下
#   row5  薄い区切り (罫線なし)
#   row6  得意分野    row7 得意技術    row8 得意業務
#   row9  薄い区切り
#   row10 自己PR | 値(C:Q, 文字量に合わせて高く)
#   row11 薄い区切り
#   row12 職務経歴ヘッダ(期間 A:D / 業務内容 E / 役割..ツール F..J / 担当工程 K:Q)
#   row13 担当工程の工程名 (7工程)
#   row14.. 案件ブロック = 3行
#   ※ 最寄駅・F列の右側ボックスは廃止 (縦1列に統一)
#
# ポイント:
#   - 区切り行(SEP)は薄く・罫線なし → 「空欄に線が入った余計な行」に見えないようにする
#   - 罫線は本文ブロックにだけ引く (区切り行をまたがない)
#   - 行高は AutoResize を使わず、本文の文字量から算出して結合セルが潰れないようにする
# 書き込みは OAuth 必須。トークンは引数 user (無ければ admin=西野 にフォールバック)。
class SkillSheetExporter
  COLS         = 17 # A..Q
  PHASE_KEYS   = SkillSheetProject::PHASE_KEYS # 7 工程
  PHASE_START  = 10 # K列 (0-indexed)
  LABEL_BG     = [0.6, 0.8, 1.0].freeze
  BORDER_COLOR = [0.0, 0.0, 0.0].freeze

  # 行位置 (0-indexed)
  # 上部ブロックは全て「ラベル A:B + 値 C:Q」の縦1列 (得意分野と同じ形)。
  # 性別は稼動開始の下に独立行。最寄駅・F列の右側ボックスは廃止。
  TITLE_ROW     = 0
  NAME_ROW      = 1
  AGE_ROW       = 2
  START_ROW     = 3
  GENDER_ROW    = 4
  SEP1_ROW      = 5
  SPECIAL_ROW   = 6
  SKILL_ROW     = 7
  DUTY_ROW      = 8
  SEP2_ROW      = 9
  PR_ROW        = 10
  SEP3_ROW      = 11
  HEADER_ROW    = 12
  PHASE_HDR_ROW = 13
  PROJECT_TOP   = 14
  PROJECT_SPAN  = 3

  # 上部の「ラベル+値(C:Q)」行 (技術者名/年齢/稼動開始/性別/得意分野/得意技術/得意業務/自己PR)
  INFO_ROWS = [ NAME_ROW, AGE_ROW, START_ROW, GENDER_ROW, SPECIAL_ROW, SKILL_ROW, DUTY_ROW, PR_ROW ].freeze

  SEP_ROWS    = [SEP1_ROW, SEP2_ROW, SEP3_ROW].freeze
  SEP_HEIGHTS = { SEP1_ROW => 8, SEP2_ROW => 7, SEP3_ROW => 10 }.freeze

  # 見本実測の列幅 (A..Q)
  COL_WIDTHS = [41, 104, 25, 100, 827, 111, 100, 100, 100, 101, 31, 34, 30, 28, 27, 28, 29].freeze

  # 行高さ算出パラメータ (文字が切れないよう少し余裕を持たせる)
  LINE_PX      = 22 # 1 行ぶんの高さ目安 (10pt の実行高 + 余白)
  MIN_ROW_PX   = 21 # 1 行セルの最低高さ (見本準拠)
  FULL_CHAR_PX = 15 # 全角 1 文字ぶんの横幅目安 (折返しを多めに見積もり切れ防止)
  HALF_CHAR_PX = 8  # 半角(ASCII) 1 文字ぶんの横幅目安
  CELL_PAD_PX  = 12 # セル左右の内側余白の合計 (この分だけ折返し可能幅が減る)

  def initialize(skill_sheet:, user:)
    @skill_sheet    = skill_sheet
    @user           = user
    @spreadsheet_id = skill_sheet.spreadsheet_id.presence || extract_id(skill_sheet.spreadsheet_url)
    # 書き出し先タブ: export_gid(書き出し専用に固定したタブ)を最優先。
    # import が取り込み元タブの gid を保存しても、export_gid があれば書き出し先はそちらに固定される
    # (須崎さんの専用テンプレタブのように「取り込み元≠書き出し先」を実現する)。
    @gid = skill_sheet.export_gid.presence || skill_sheet.gid.presence || "0"
  end

  def call
    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = GoogleAuth.build_writer(@user)

    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    sheet    = spreadsheet.sheets.find { |s| s.properties.sheet_id.to_s == @gid } || spreadsheet.sheets.first
    sheet_id = sheet.properties.sheet_id
    title    = sheet.properties.title
    grid     = sheet.properties.grid_properties

    values     = build_matrix
    total_rows = values.size

    reset_sheet(service, title, sheet_id)
    service.update_spreadsheet_value(
      @spreadsheet_id, "#{title}!A1",
      Google::Apis::SheetsV4::ValueRange.new(values: values),
      value_input_option: "RAW"
    )
    apply_format(service, sheet_id, total_rows)
    write_period_formulas(service, title)  # 期間を実日付化し、補足セルに DATEDIF 関数を入れる
    trim_sheet(service, sheet_id, total_rows, grid&.row_count.to_i, grid&.column_count.to_i) # 本文より下・右の空行列を削除

    @skill_sheet.update!(synced_at: Time.current)
    { spreadsheet_id: @spreadsheet_id, gid: @gid, rows: total_rows }
  rescue Google::Apis::ClientError => e
    raise format_permission_error(e)
  end

  private

  def extract_id(url)
    url.to_s[%r{/spreadsheets/d/([a-zA-Z0-9_-]+)}, 1] or raise "スプレッドシートの URL が不正です"
  end

  def projects
    @projects ||= @skill_sheet.projects.order(:position)
  end

  # ── 値マトリクス生成 ────────────────────────────────
  def empty_row = Array.new(COLS, "")

  def put(rows, row_index, col_index, value)
    rows[row_index][col_index] = value.to_s
  end

  def build_matrix
    s = @skill_sheet
    rows = Array.new(PROJECT_TOP + projects.size * PROJECT_SPAN) { empty_row }

    put(rows, TITLE_ROW, 0, "スキルシート")
    # 上部は全て「ラベル A:B + 値 C:Q」の縦1列 (得意分野と同じ形)。
    put(rows, NAME_ROW, 0, "技術者名"); put(rows, NAME_ROW, 2, s.engineer_name)
    put(rows, AGE_ROW, 0, "年　　齢");  put(rows, AGE_ROW, 2, s.age)
    put(rows, START_ROW, 0, "稼動開始"); put(rows, START_ROW, 2, s.start_date)
    put(rows, GENDER_ROW, 0, "性　　別"); put(rows, GENDER_ROW, 2, s.gender)
    put(rows, SPECIAL_ROW, 0, "得意分野"); put(rows, SPECIAL_ROW, 2, s.specialties)
    put(rows, SKILL_ROW, 0, "得意技術");   put(rows, SKILL_ROW, 2, s.skills)
    put(rows, DUTY_ROW, 0, "得意業務");    put(rows, DUTY_ROW, 2, s.duties)
    put(rows, PR_ROW, 0, "自己PR");        put(rows, PR_ROW, 2, s.self_pr)

    put(rows, HEADER_ROW, 0, "期間"); put(rows, HEADER_ROW, 4, "業務内容")
    put(rows, HEADER_ROW, 5, "役割\n規模"); put(rows, HEADER_ROW, 6, "使用言語")
    put(rows, HEADER_ROW, 7, "DB"); put(rows, HEADER_ROW, 8, "サーバOS")
    put(rows, HEADER_ROW, 9, "FW・MW\nツール等"); put(rows, HEADER_ROW, PHASE_START, "担当工程")
    PHASE_KEYS.each_with_index { |key, i| put(rows, PHASE_HDR_ROW, PHASE_START + i, key) }

    projects.each_with_index do |project, idx|
      base = PROJECT_TOP + idx * PROJECT_SPAN
      title_line, detail = project_title_and_detail(project)
      put(rows, base, 0, (idx + 1).to_s)
      put(rows, base, 1, project.period_from)
      put(rows, base, 2, "-")
      put(rows, base, 3, project.period_to)
      put(rows, base + 2, 1, period_supplement(project)) # （Nヶ月間）
      put(rows, base, 4, title_line)
      put(rows, base + 1, 4, detail)
      put(rows, base, 5, project.role_scale)
      put(rows, base, 6, split_tech_lines(project.languages)) # 1技術1行に分割して表示
      put(rows, base, 7, split_tech_lines(project.db))
      put(rows, base, 8, split_tech_lines(project.server_os))
      put(rows, base, 9, split_tech_lines(project.tools))
      phases = project.phases.to_h
      PHASE_KEYS.each_with_index { |key, i| put(rows, base, PHASE_START + i, phases[key] ? "●" : "") }
    end
    rows
  end

  # プロジェクト名(title)と業務内容(detail)を返す。
  # title カラムがあればそれを採用、無ければ旧データ互換で description の■行から切り出す。
  def project_title_and_detail(project)
    if project.title.present?
      [project.title, project.description.to_s]
    else
      split_description(project.description)
    end
  end

  # 業務内容を「タイトル行(■概要)」と「詳細(≪担当業務≫…)」に分割。改行が無ければ全文を詳細へ。
  def split_description(text)
    body = text.to_s
    return ["", ""] if body.strip.empty?
    head, _, rest = body.partition("\n")
    if head.start_with?("■") && !rest.strip.empty?
      [head, rest]
    else
      ["", body]
    end
  end

  # 技術欄(使用言語/DB/サーバOS/FW・MW・ツール)を 1 技術 1 行(改行区切り)に分割する。
  #   スラッシュ/中黒/カンマで分け、スペース区切りはバージョン番号を直前へ結合。
  #   マスタにある複数語名(Ruby on Rails / Tailwind CSS 等)は結合維持。
  def split_tech_lines(value)
    text = value.to_s
    return "" if text.strip.empty?
    chunks = text.gsub(%r{[／/、，;；・]+}, "\n").split("\n").map(&:strip).reject(&:empty?)
    out = []
    chunks.each do |chunk|
      unless chunk.match?(/\s/)
        out << chunk
        next
      end
      tokens = chunk.split(/\s+/)
      i = 0
      while i < tokens.length
        merged = nil
        len = 1
        tokens.length.downto(i + 1) do |j|
          candidate = tokens[i...j].join(" ")
          if known_multiword_techs.include?(candidate.downcase)
            merged = candidate
            len = j - i
            break
          end
        end
        token = merged || tokens[i]
        if merged.nil? && !out.empty? && tech_version_like?(token)
          out[-1] = "#{out[-1]} #{token}"
        else
          out << token
        end
        i += len
      end
    end
    out.uniq.join("\n")
  end

  def tech_version_like?(token)
    token.match?(/\A[v]?\d[\d.]*\z/i) || token.match?(/\A[（(].*[）)]\z/)
  end

  def known_multiword_techs
    @known_multiword_techs ||=
      SkillSheetTechCatalog::MASTER.values.flatten.select { |name| name.include?(" ") }.map(&:downcase)
  end

  # 期間から「（Nヶ月間）」を算出。読み取れなければ空。
  def period_supplement(project)
    months = period_months(project.period_from, project.period_to)
    months ? "（#{months}ヶ月間）" : ""
  end

  def period_months(period_from, period_to)
    from = year_month(period_from)
    return nil unless from
    to = year_month(period_to) || current_year_month
    [(to - from) + 1, 1].max
  end

  # "2025年11月" / "2025/11" → 通算月 (year*12+month)。"現在"等は当月。
  def year_month(value)
    text = value.to_s.strip
    return current_year_month if text.match?(/現在|present|即日|now/i)
    matched = text.match(/(\d{4})\s*[年\/.\-]\s*(\d{1,2})/)
    matched ? matched[1].to_i * 12 + matched[2].to_i : nil
  end

  def current_year_month
    @current_year_month ||= begin
      today = Time.zone&.today || Date.today
      today.year * 12 + today.month
    end
  end

  # "2025年11月"/"2025/11" → その月の 1 日(Date)。日付化できなければ nil(現在/即日/空 を含む)。
  def month_date(value)
    matched = value.to_s.match(/(\d{4})\s*[年\/.\-]\s*(\d{1,2})/)
    return nil unless matched
    Date.new(matched[1].to_i, matched[2].to_i, 1)
  rescue ArgumentError
    nil
  end

  # 期間 from/to を実日付化(yyyy年m月表示)し、補足セルに DATEDIF 関数を入れる。
  # from が日付化できない案件は build_matrix の Ruby 計算「（Nヶ月間）」テキストのまま残す。
  def write_period_formulas(service, title)
    value_ranges = []
    format_requests = []
    projects.each_with_index do |project, idx|
      from_date = month_date(project.period_from)
      next unless from_date
      row = PROJECT_TOP + idx * PROJECT_SPAN + 1 # 1-indexed: 期間 from/to の行
      supplement_row = row + 2                    # （Nヶ月間）の行

      value_ranges << a1_value(title, "B#{row}", from_date.strftime("%Y/%m/%d"))
      format_requests << date_format_request(row - 1, 1) # B列(0-indexed col=1)

      to_date = month_date(project.period_to)
      if to_date
        value_ranges << a1_value(title, "D#{row}", to_date.strftime("%Y/%m/%d"))
        format_requests << date_format_request(row - 1, 3) # D列
        formula = %Q{="（"&DATEDIF(B#{row},D#{row},"M")+1&"ヶ月間）"}
      else
        # period_to が "現在/即日" 等 → TODAY() で当月まで算出
        formula = %Q{="（"&DATEDIF(B#{row},TODAY(),"M")+1&"ヶ月間）"}
      end
      value_ranges << a1_value(title, "B#{supplement_row}", formula)
    end
    return if value_ranges.empty?

    service.batch_update_values(@spreadsheet_id, Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(
      value_input_option: "USER_ENTERED", data: value_ranges))
    unless format_requests.empty?
      service.batch_update_spreadsheet(@spreadsheet_id,
        Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: format_requests))
    end
  end

  def a1_value(title, a1, value)
    Google::Apis::SheetsV4::ValueRange.new(range: "#{title}!#{a1}", values: [ [ value ] ])
  end

  def date_format_request(row0, col0)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: grid(row0, row0 + 1, col0, col0 + 1),
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        number_format: Google::Apis::SheetsV4::NumberFormat.new(type: "DATE", pattern: "yyyy\"年\"m\"月\""))),
      fields: "userEnteredFormat.numberFormat"))
  end

  # ── 旧状態クリア (値・結合・罫線) ──────────────────
  def reset_sheet(service, title, sheet_id)
    service.clear_values(@spreadsheet_id, "#{title}!A1:Z1000")
    full = Google::Apis::SheetsV4::GridRange.new(
      sheet_id: sheet_id, start_row_index: 0, end_row_index: 1000, start_column_index: 0, end_column_index: 26
    )
    # 結合解除はシート全体(sheet_id のみ＝全セル)を対象にする。
    # A1:Z1000 のような固定範囲だと、既存の結合がその範囲外(列Zより右・行1000より下)まで
    # またがっている場合に「結合範囲のすべてのセルを選択する必要があります」(Invalid request)で失敗する。
    whole_sheet = Google::Apis::SheetsV4::GridRange.new(sheet_id: sheet_id)
    requests = [
      # 既存の基本フィルタを解除する。テンプレートによってはフィルタが掛かっており、
      # その境界をまたいでセル結合しようとすると「既存のフィルタの境界をまたいでセル同士を結合することはできません」で失敗する。
      Google::Apis::SheetsV4::Request.new(
        clear_basic_filter: Google::Apis::SheetsV4::ClearBasicFilterRequest.new(sheet_id: sheet_id)
      ),
      Google::Apis::SheetsV4::Request.new(
        unmerge_cells: Google::Apis::SheetsV4::UnmergeCellsRequest.new(range: whole_sheet)
      ),
      Google::Apis::SheetsV4::Request.new(
        update_borders: Google::Apis::SheetsV4::UpdateBordersRequest.new(
          range: full, top: none_border, bottom: none_border, left: none_border, right: none_border,
          inner_horizontal: none_border, inner_vertical: none_border
        )
      ),
      Google::Apis::SheetsV4::Request.new(
        # 背景を白に戻すと同時に、フォントも 10pt(既定) に正規化する。
        # これをやらないと、書き出し先テンプレート側の大きいフォント(見出し等)が
        # 値だけ上書きした後も残り「文字がめちゃくちゃ大きくなる」ため。bold は後段で再付与。
        repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
          range: full,
          cell: Google::Apis::SheetsV4::CellData.new(
            user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
              background_color: Google::Apis::SheetsV4::Color.new(red: 1, green: 1, blue: 1),
              text_format: Google::Apis::SheetsV4::TextFormat.new(font_size: 10, font_family: "Arial", bold: false)
            )
          ),
          fields: "userEnteredFormat.backgroundColor,userEnteredFormat.textFormat"
        )
      )
    ]
    service.batch_update_spreadsheet(@spreadsheet_id,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests))
  end

  def none_border = Google::Apis::SheetsV4::Border.new(style: "NONE")

  # 本文(total_rows × COLS)より下の空行・右の空列を削除して、
  # 「20行目以降に線が残る(=空セルのグリッド線/旧罫線)」状態をなくす。
  def trim_sheet(service, sheet_id, total_rows, row_count, col_count)
    requests = []
    if row_count > total_rows
      requests << delete_dimension(sheet_id, "ROWS", total_rows, row_count)
    end
    if col_count > COLS
      requests << delete_dimension(sheet_id, "COLUMNS", COLS, col_count)
    end
    return if requests.empty?
    service.batch_update_spreadsheet(@spreadsheet_id,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests))
  end

  def delete_dimension(sheet_id, dimension, start_index, end_index)
    Google::Apis::SheetsV4::Request.new(delete_dimension: Google::Apis::SheetsV4::DeleteDimensionRequest.new(
      range: Google::Apis::SheetsV4::DimensionRange.new(
        sheet_id: sheet_id, dimension: dimension, start_index: start_index, end_index: end_index)))
  end

  # ── 整形 (見本レイアウト適用) ─────────────────────
  def apply_format(service, sheet_id, total_rows)
    @sheet_id = sheet_id
    requests = []
    requests << hide_gridlines_request # 見本同様、グリッド線を消し明示罫線の本文だけ枠線を見せる
    requests.concat(merge_requests)
    requests.concat(border_requests(total_rows))           # 本文ブロックのみ実線 (区切り行は除外)
    requests << wrap_request(grid(0, total_rows, 0, COLS))  # 折り返し
    requests << align_request(grid(0, total_rows, 0, COLS), "CENTER", "MIDDLE") # 全体を上下左右中央
    requests.concat(left_align_requests)                   # 長文セルだけ左寄せ(段落の可読性確保)
    requests.concat(label_bg_requests)
    requests.concat(bold_requests)
    requests.concat(column_width_requests)
    requests.concat(row_height_requests(total_rows))
    service.batch_update_spreadsheet(@spreadsheet_id,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests))
  end

  def hide_gridlines_request
    Google::Apis::SheetsV4::Request.new(update_sheet_properties: Google::Apis::SheetsV4::UpdateSheetPropertiesRequest.new(
      properties: Google::Apis::SheetsV4::SheetProperties.new(
        sheet_id: @sheet_id,
        grid_properties: Google::Apis::SheetsV4::GridProperties.new(hide_gridlines: true)),
      fields: "gridProperties.hideGridlines"))
  end

  def grid(r1, r2, c1, c2)
    Google::Apis::SheetsV4::GridRange.new(
      sheet_id: @sheet_id, start_row_index: r1, end_row_index: r2, start_column_index: c1, end_column_index: c2
    )
  end

  def merge(r1, r2, c1, c2)
    Google::Apis::SheetsV4::Request.new(
      merge_cells: Google::Apis::SheetsV4::MergeCellsRequest.new(range: grid(r1, r2, c1, c2), merge_type: "MERGE_ALL")
    )
  end

  def merge_requests
    m = []
    m << merge(TITLE_ROW, TITLE_ROW + 1, 0, COLS)
    SEP_ROWS.each { |r| m << merge(r, r + 1, 0, COLS) }
    # 上部ブロックは全て「ラベル A:B + 値 C:Q」の縦1列に統一 (技術者名/年齢/稼動開始/性別/得意◯◯/自己PR)
    INFO_ROWS.each do |r|
      m << merge(r, r + 1, 0, 2)    # ラベル A:B
      m << merge(r, r + 1, 2, COLS) # 値 C:Q
    end
    # ヘッダ
    m << merge(HEADER_ROW, PHASE_HDR_ROW + 1, 0, 4) # 期間 A:D
    (4..9).each { |c| m << merge(HEADER_ROW, PHASE_HDR_ROW + 1, c, c + 1) }
    m << merge(HEADER_ROW, HEADER_ROW + 1, PHASE_START, COLS) # 担当工程 K:Q
    # 案件ブロック
    projects.size.times do |idx|
      b = PROJECT_TOP + idx * PROJECT_SPAN
      m << merge(b, b + PROJECT_SPAN, 0, 1)      # No (3行)
      m << merge(b, b + 2, 1, 2)                 # 期間from (2行)
      m << merge(b, b + 2, 2, 3)                 # "-"
      m << merge(b, b + 2, 3, 4)                 # 期間to
      m << merge(b + 2, b + PROJECT_SPAN, 1, 4)  # 期間補足 （Nヶ月間） B:D
      m << merge(b + 1, b + PROJECT_SPAN, 4, 5)  # 業務内容詳細 (2行)
      (5..9).each { |c| m << merge(b, b + PROJECT_SPAN, c, c + 1) } # 役割/言語/DB/OS/ツール (3行)
      (PHASE_START...COLS).each { |c| m << merge(b, b + PROJECT_SPAN, c, c + 1) } # 工程● (3行)
    end
    m
  end

  # ── 罫線: 区切り行をまたがない本文ブロック単位で実線 ──
  def border_requests(total_rows)
    border_blocks(total_rows).map { |r1, r2| border_request(grid(r1, r2, 0, COLS)) }
  end

  # 罫線を引く行レンジ (区切り行 SEP を除外して分割)。
  def border_blocks(total_rows)
    [
      [TITLE_ROW, SEP1_ROW],         # タイトル+技術者名..稼動開始
      [SPECIAL_ROW, SEP2_ROW],       # 得意分野..得意業務
      [PR_ROW, SEP3_ROW],            # 自己PR
      [HEADER_ROW, total_rows]       # 職務経歴ヘッダ..案件
    ]
  end

  def border_request(range)
    border = Google::Apis::SheetsV4::Border.new(
      style: "SOLID",
      color: Google::Apis::SheetsV4::Color.new(red: BORDER_COLOR[0], green: BORDER_COLOR[1], blue: BORDER_COLOR[2])
    )
    Google::Apis::SheetsV4::Request.new(update_borders: Google::Apis::SheetsV4::UpdateBordersRequest.new(
      range: range, top: border, bottom: border, left: border, right: border,
      inner_horizontal: border, inner_vertical: border))
  end

  def wrap_request(range)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: range,
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        wrap_strategy: "WRAP")),
      fields: "userEnteredFormat.wrapStrategy"))
  end

  def align_request(range, horizontal, vertical)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: range,
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        horizontal_alignment: horizontal, vertical_alignment: vertical)),
      fields: "userEnteredFormat.horizontalAlignment,userEnteredFormat.verticalAlignment"))
  end

  # 長文セル(自己PR・業務内容詳細)は中央寄せだと段落が読みにくいので左寄せ・上揃え。
  def left_align_requests
    reqs = [
      # 上部の値はすべて C:Q・左寄せ上揃え (技術者名/年齢/稼動開始/性別/得意◯◯/自己PR)
      align_request(grid(NAME_ROW, GENDER_ROW + 1, 2, COLS), "LEFT", "TOP"),
      align_request(grid(SPECIAL_ROW, DUTY_ROW + 1, 2, COLS), "LEFT", "TOP"),
      align_request(grid(PR_ROW, PR_ROW + 1, 2, COLS), "LEFT", "TOP")
    ]
    projects.size.times do |idx|
      b = PROJECT_TOP + idx * PROJECT_SPAN
      reqs << align_request(grid(b, b + 1, 4, 5), "LEFT", "TOP")               # プロジェクトタイトル(E)
      reqs << align_request(grid(b + 1, b + PROJECT_SPAN, 4, 5), "LEFT", "TOP") # 業務内容詳細(E)
    end
    reqs
  end

  def bg_request(range)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: range,
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        background_color: Google::Apis::SheetsV4::Color.new(red: LABEL_BG[0], green: LABEL_BG[1], blue: LABEL_BG[2]))),
      fields: "userEnteredFormat.backgroundColor"))
  end

  def label_bg_requests
    r = []
    INFO_ROWS.each { |row| r << bg_request(grid(row, row + 1, 0, 2)) } # ラベル A:B のみ
    r << bg_request(grid(HEADER_ROW, PHASE_HDR_ROW + 1, 0, COLS)) # ヘッダ全体
    projects.size.times do |idx|
      b = PROJECT_TOP + idx * PROJECT_SPAN
      r << bg_request(grid(b, b + PROJECT_SPAN, 0, 1)) # No 列
    end
    r
  end

  def bold_request(range)
    Google::Apis::SheetsV4::Request.new(repeat_cell: Google::Apis::SheetsV4::RepeatCellRequest.new(
      range: range,
      cell: Google::Apis::SheetsV4::CellData.new(user_entered_format: Google::Apis::SheetsV4::CellFormat.new(
        text_format: Google::Apis::SheetsV4::TextFormat.new(bold: true))),
      fields: "userEnteredFormat.textFormat.bold"))
  end

  def bold_requests
    [
      bold_request(grid(TITLE_ROW, TITLE_ROW + 1, 0, COLS)),
      bold_request(grid(NAME_ROW, PR_ROW + 1, 0, 2)), # 上部ラベル A:B (技術者名..自己PR)
      bold_request(grid(HEADER_ROW, PHASE_HDR_ROW + 1, 0, COLS))
    ]
  end

  def column_width_requests
    COL_WIDTHS.each_with_index.map do |px, i|
      Google::Apis::SheetsV4::Request.new(update_dimension_properties: Google::Apis::SheetsV4::UpdateDimensionPropertiesRequest.new(
        range: Google::Apis::SheetsV4::DimensionRange.new(sheet_id: @sheet_id, dimension: "COLUMNS", start_index: i, end_index: i + 1),
        properties: Google::Apis::SheetsV4::DimensionProperties.new(pixel_size: px), fields: "pixelSize"))
    end
  end

  # ── 行高さ: 本文の文字量から算出 (AutoResize は結合セルを潰すため不使用) ──
  # 全角/半角で文字幅を重み付けし、セル幅から折返し行数を見積もる。
  # 一律幅(旧 CHAR_PX)だと全角主体の日本語で折返しを過小評価し、文章が途中で切れていた。
  def segment_width_px(segment)
    segment.chars.sum { |ch| ch.ascii_only? ? HALF_CHAR_PX : FULL_CHAR_PX }
  end

  def wrapped_lines(text, width_px)
    usable = [width_px - CELL_PAD_PX, FULL_CHAR_PX].max
    text.to_s.split("\n").sum { |segment| [(segment_width_px(segment).to_f / usable).ceil, 1].max }
  end

  def cell_px(text, width_px)
    [wrapped_lines(text, width_px) * LINE_PX + 10, MIN_ROW_PX].max
  end

  def col_px(col_index) = COL_WIDTHS[col_index]
  def span_px(c1, c2) = COL_WIDTHS[c1...c2].sum

  def row_height_requests(total_rows)
    heights = Array.new(total_rows, MIN_ROW_PX)
    value_width = span_px(2, COLS) # 得意◯◯・自己PR の値セル幅 (C:Q)

    SEP_HEIGHTS.each { |row, px| heights[row] = px } # 区切り行は薄く

    [[SPECIAL_ROW, @skill_sheet.specialties], [SKILL_ROW, @skill_sheet.skills],
     [DUTY_ROW, @skill_sheet.duties], [PR_ROW, @skill_sheet.self_pr]].each do |row, text|
      heights[row] = cell_px(text, value_width)
    end
    # ヘッダは「役割\n規模」「FW・MW\nツール等」等の2行ラベルが切れないよう確保。
    # 期間 A:D や 役割..ツールは HEADER_ROW..PHASE_HDR_ROW の2行結合なので合計で2行ぶん入ればよい。
    heights[HEADER_ROW]    = MIN_ROW_PX
    # 担当工程の工程名 (狭い列に「要件定義」等) は縦に伸びるので固めに
    heights[PHASE_HDR_ROW] = [cell_px("要件定義", col_px(PHASE_START)), LINE_PX * 2 + 10].max

    projects.each_with_index do |project, idx|
      base = PROJECT_TOP + idx * PROJECT_SPAN
      title_line, detail = project_title_and_detail(project)
      h_line1 = [cell_px(title_line, col_px(4)), MIN_ROW_PX].max
      h_detail = cell_px(detail, col_px(4))
      h_supp = MIN_ROW_PX
      # 役割/言語/DB/OS/ツール (3行縦結合) に必要な高さ
      h_side = [5, 6, 7, 8, 9].map { |c| cell_px(project_value(project, c), col_px(c)) }.max
      # 詳細行は「詳細テキストに必要な高さ」と「横結合セルを賄うのに必要な残り」の大きい方。
      # こうしないと役割/ツール等が長いとき詳細行に回る高さが足りず文章が切れる。
      heights[base]     = h_line1
      heights[base + 2] = h_supp
      heights[base + 1] = [h_detail, h_side - h_line1 - h_supp, MIN_ROW_PX].max
    end

    heights.each_index.map { |row| dimension_height(row, heights[row]) }
  end

  def project_value(project, col)
    { 5 => project.role_scale, 6 => project.languages, 7 => project.db,
      8 => project.server_os, 9 => project.tools }[col]
  end

  def dimension_height(row_index, px)
    Google::Apis::SheetsV4::Request.new(update_dimension_properties: Google::Apis::SheetsV4::UpdateDimensionPropertiesRequest.new(
      range: Google::Apis::SheetsV4::DimensionRange.new(sheet_id: @sheet_id, dimension: "ROWS", start_index: row_index, end_index: row_index + 1),
      properties: Google::Apis::SheetsV4::DimensionProperties.new(pixel_size: px), fields: "pixelSize"))
  end

  def format_permission_error(e)
    if e.status_code == 403 || e.message.to_s.include?("permission")
      writer = GoogleAuth.writer_user(@user)
      "スプレッドシートへの書き込み権限がありません。対象シートを #{writer&.email} に「編集者」として共有してください。"
    else
      "スプレッドシートへの書き込みに失敗しました: #{e.message}"
    end
  end
end
