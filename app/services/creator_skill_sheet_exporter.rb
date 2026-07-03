require "google/apis/sheets_v4"

# クリエイター(デザイン・動画編集)用スキルシートの書き出し。
# エンジニア用 SkillSheetExporter のように版面を作り直さず、
# 既存の「デザイン・クリエイター」テンプレートが入ったタブ(export_gid)へ DB の値だけを流し込む。
# → ボタンを押してもレイアウト(エンジニア形)に潰れず、手で整えた版面・手入力セルも壊さない。
#
# 版面そのものが壊れている/未作成の場合は tmp/rebuild_susaki_creator.rb で
# テンプレ(「スキルシート(デザイン・クリエイター)」)から復元してから本クラスで値を入れる。
class CreatorSkillSheetExporter
  # 記入例(gid=346304297)と同じセル位置。DB の項目をここへ書き込む。
  def initialize(skill_sheet:, user:)
    @skill_sheet    = skill_sheet
    @user           = user
    @spreadsheet_id = skill_sheet.spreadsheet_id.presence || extract_id(skill_sheet.spreadsheet_url)
    @gid            = skill_sheet.export_gid.presence || skill_sheet.gid.presence || "0"
  end

  def call
    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = GoogleAuth.build_writer(@user)

    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    sheet = spreadsheet.sheets.find { |s| s.properties.sheet_id.to_s == @gid.to_s } || spreadsheet.sheets.first
    title = sheet.properties.title
    @sheet_id = sheet.properties.sheet_id

    cells = build_cells
    data = cells.map { |cell, value| Google::Apis::SheetsV4::ValueRange.new(range: "'#{title}'!#{cell}", values: [ [ value ] ]) }
    service.batch_update_values(@spreadsheet_id, Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(
      value_input_option: "USER_ENTERED", data: data))

    # 不要部分を非表示にして整理(削除ではなく hide=セル位置を保ち再書き出しを壊さない)。
    tidy_layout(service, @skill_sheet.projects.count)

    @skill_sheet.update!(synced_at: Time.current)
    { spreadsheet_id: @spreadsheet_id, gid: @gid, rows: data.size }
  rescue Google::Apis::ClientError => e
    raise format_permission_error(e)
  end

  # 案件数に応じて空き案件ブロック / 右側の空き列 / 下の空き行を非表示にして整理する。
  # 非表示なのでセル位置は不変＝再書き出し時も同じセルに入る。案件を増やせば該当ブロックは再表示。
  PROJECT_BLOCKS   = 6   # テンプレの案件枠数(No.1〜No.6)
  CONTENT_LAST_ROW = 97  # これより下(98行〜)は空き(0-indexed 97)
  USED_LAST_COL0   = 76  # BY 列(0-indexed)まで使用。BZ(77)以降は空き

  def tidy_layout(service, project_count)
    requests = []
    PROJECT_BLOCKS.times do |index|
      top0 = (PROJECT_ROW_TOP - 1) + index * PROJECT_ROW_SPAN
      requests << hide_dimension("ROWS", top0, top0 + PROJECT_ROW_SPAN, index >= project_count)
    end
    requests << hide_dimension("ROWS", CONTENT_LAST_ROW, 297, true)      # 下の空き行(98行〜)
    requests << hide_dimension("COLUMNS", USED_LAST_COL0 + 1, 100, true) # 右の空き列(BZ〜)
    service.batch_update_spreadsheet(@spreadsheet_id,
      Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests))
  end

  def hide_dimension(dimension, start0, end0, hidden)
    Google::Apis::SheetsV4::Request.new(update_dimension_properties: Google::Apis::SheetsV4::UpdateDimensionPropertiesRequest.new(
      range: Google::Apis::SheetsV4::DimensionRange.new(sheet_id: @sheet_id, dimension: dimension, start_index: start0, end_index: end0),
      properties: Google::Apis::SheetsV4::DimensionProperties.new(hidden_by_user: hidden), fields: "hiddenByUser"))
  end

  private

  def extract_id(url)
    url.to_s[%r{/spreadsheets/d/([a-zA-Z0-9_-]+)}, 1] or raise "スプレッドシートの URL が不正です"
  end

  # クリエイターテンプレ(897364072)の入力セル位置。値が空の項目は上書きしない
  # (手入力したフリガナ等を消さないため reject で除外)。
  PROJECT_ROW_TOP  = 43 # 案件No.1 の先頭行
  PROJECT_ROW_SPAN = 6  # 1案件=6行(No.1=43, No.2=49, No.3=55, ...)

  # スキル評価グリッド: スキル名 → 評価レベル(A〜E)を書き込むセル(ラベルの1つ下の行)。
  # 列 H/O/V/AC/AJ/AQ/AX/BE/BL/BS、レベル行はラベル行+1(82/84/86/88/90/92/94/96)。
  GRID_LEVEL_CELLS = {
    # 担当・経験/領域 (82)
    "UI/UX設計" => "H82", "IA設計" => "O82", "デザイン" => "V82", "コーディング" => "AC82", "ディレクション" => "AJ82", "プランニング" => "AQ82",
    # 担当・経験/領域 (84)
    "レスポンシブ対応" => "H84", "クロスブラウザ対応" => "O84", "アプリデザイン" => "V84", "Webマーケティング" => "AC84", "顧客折衝" => "AJ84", "スケジュール管理" => "AQ84",
    # ツール (86)
    "Photoshop" => "H86", "Illustrator" => "O86", "Sketch" => "V86", "AdobeXD" => "AC86", "Prott" => "AJ86", "inVision" => "AQ86", "Cacoo" => "AX86", "Sublime Text" => "BE86", "Atom" => "BL86", "Dreamweaver" => "BS86",
    # ツール (88)
    "Git" => "H88", "Gulp" => "O88", "Grunt" => "V88", "Webpack" => "AC88", "Redmine" => "AJ88", "JIRA" => "AQ88", "Backlog" => "AX88", "Google Analytics" => "BE88", "WordPress" => "BL88", "EC-CUBE" => "BS88",
    # ツール (90)
    "Visual Studio" => "H90", "unity" => "O90", "Unreal Engine" => "V90", "figma" => "AC90", "WORD" => "AJ90", "EXCEL" => "AQ90", "Power Point" => "AX90",
    # 言語等 (92)
    "HTML5" => "H92", "CSS3" => "O92", "JavaScript" => "V92", "PHP" => "AC92", "Sass" => "AJ92", "Stylus" => "AQ92", "Pug" => "AX92", "TypeScript" => "BE92", "CoffeeScript" => "BL92", "ES6" => "BS92",
    # 言語等 (94)
    "C" => "H94", "C＋＋" => "O94", "C#" => "V94",
    # フレームワーク/ライブラリ (96)
    "React.js" => "H96", "Vue.js" => "O96", "Angular2" => "V96", "Backbone.js" => "AC96", "Node.js" => "AJ96", "Riot.js" => "AQ96", "jQuery" => "AX96"
  }.freeze

  # 表記ゆれ(大文字小文字・空白)を吸収して引けるよう正規化キーの索引も作る。
  GRID_NORMALIZED = GRID_LEVEL_CELLS.transform_keys { |k| k.downcase.delete(" 　") }.freeze

  def build_cells
    s = @skill_sheet
    cells = {
      # 赤枠(受領後削除される個人情報欄)
      "H4"  => s.engineer_name,        # 氏名
      "H6"  => s.address,              # 住所
      "H10" => s.user&.email,          # メールアドレス
      # 技術経歴書(本体)
      "B21" => s.engineer_name,        # 名前
      "R21" => s.age,                  # 年齢
      "Y21" => s.gender,               # 性別
      "I28" => s.self_pr               # スキル要約(自己PR)
    }
    # 参画開始可能日 → 年(L23)/月(R23)/日(V23)
    start_year, start_month, start_day = parse_ymd(s.start_date)
    cells["L23"] = start_year
    cells["R23"] = start_month
    cells["V23"] = start_day

    # 案件ブロック(6行ごと)。期間・タイトル・業務内容・使用ソフト・役割を埋める。
    s.projects.order(:position).each_with_index do |project, index|
      base = PROJECT_ROW_TOP + index * PROJECT_ROW_SPAN
      break if base > 250 # テンプレ範囲を超えたら止める(安全)
      from_year, from_month = parse_ym(project.period_from)
      to_year,   to_month   = parse_ym(project.period_to)
      cells["D#{base}"]      = from_year   # 期間 開始 年
      cells["I#{base}"]      = from_month  # 期間 開始 月
      cells["D#{base + 2}"]  = to_year     # 期間 終了 年
      cells["I#{base + 2}"]  = to_month    # 期間 終了 月
      cells["M#{base}"]      = project.title       # 業務内容タイトル
      cells["M#{base + 1}"]  = project.description # 業務内容 詳細
      # 使用ソフト/言語など: AU列は1行1セル(AU{base}..AU{base+5})。1ソフト1行で縦に並べる。
      software_items(project).first(PROJECT_ROW_SPAN).each_with_index do |item, line|
        cells["AU#{base + line}"] = item
      end
      # 役割/規模/就業形態(クリエイターテンプレ既定値)
      cells["BK#{base}"] = project.role_scale.presence || "メンバー" # 役割
      cells["BP#{base}"] = "0〜5人"                                   # 規模(既定)
      cells["BU#{base}"] = "その他"                                   # 就業形態(既定)
    end

    # スキル評価グリッド(A〜E)。スキル名→対応セルにレベルを書き込む。
    @skill_sheet.evaluations.each do |evaluation|
      cell = grid_cell_for(evaluation.label)
      cells[cell] = evaluation.level if cell
    end

    cells.reject { |_, value| value.to_s.strip.empty? }
  end

  def grid_cell_for(label)
    GRID_LEVEL_CELLS[label.to_s] || GRID_NORMALIZED[label.to_s.downcase.delete(" 　")]
  end

  # 使用ソフト/言語を「1ソフト=1要素」に分割する。
  # 区切りは 改行 / スラッシュ / 読点 / 中黒 のみ。**半角スペースでは分割しない**
  # (「Adobe Premiere Pro」「After Effects」を1要素として保つ)。
  def software_items(project)
    [ project.languages, project.tools ]
      .flat_map { |value| value.to_s.split(%r{[\n、，,／/・]+}) }
      .map(&:strip).reject(&:empty?).uniq
  end

  # "2026-03" / "2026年3月" → [年, 月]。読めなければ [nil, nil]。
  def parse_ym(value)
    matched = value.to_s.match(/(\d{4})\D+(\d{1,2})/)
    matched ? [ matched[1], matched[2] ] : [ nil, nil ]
  end

  # "2026年4月1日" / "2026-04-01" → [年, 月, 日]。日が無ければ日は nil。
  def parse_ymd(value)
    matched = value.to_s.match(/(\d{4})\D+(\d{1,2})\D+(\d{1,2})/)
    return [ matched[1], matched[2], matched[3] ] if matched
    year, month = parse_ym(value)
    [ year, month, nil ]
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
