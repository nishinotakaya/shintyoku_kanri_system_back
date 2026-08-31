require "google/apis/sheets_v4"

# BacklogTask → Google スプレッドシートに書き出す。
# 進捗管理_西野.xlsx テンプレート準拠。
# シート1: 現在のタスク（処理済→処理中→未対応）
# シート2: 完了タスク
class GoogleSheetsExporter
  # 色定義 (RGB 0-1)
  # 色を付けるのは見出しだけ:
  #   ヘッダ行(本日行う/タスク名/…/id) と セクション見出し(【処理中】など) を黄色。
  # タスク行は白。「本日行う」は A列のチェックボックスで判別するので、
  # 行を色分けする必要がなくなった(旧仕様の 黄/ピンク/紫 は廃止)。
  YELLOW = { red: 1.00, green: 0.95, blue: 0.60 }.freeze
  COLORS = {
    header_bg:    YELLOW, # ヘッダ (本日行う / タスク名 ...)
    section_done: YELLOW, # 処理済
    section_wip:  YELLOW, # 処理中
    section_todo: YELLOW, # 未対応
    completed:    YELLOW, # 完了
    white:        { red: 1.0, green: 1.0, blue: 1.0 }
  }.freeze

  # A列=チェックボックス(本日行う) / B〜I=データ / J列=タスクid(取込の突合キー・非表示)。
  # J までがデータなので 10 列。これより右(K列以降)は列ごと削除してグリッド線を消す
  DATA_COLUMN_COUNT = 10
  # 取込時に既存タスクを突き合わせる id を置く列(0-indexed)。A列はチェックボックスに使うため J へ逃がす
  ID_COLUMN_INDEX = 9

  # workspace_id: 指定するとそのワークスペース(Wing / リビング等)のタスクだけを書き出す。
  # 案件ごとに別のスプレッドシートを使うため、混ざらないようにする。
  def initialize(user:, spreadsheet_url:, only_flagged: false, workspace_id: nil)
    @user = user
    @spreadsheet_id = extract_id(spreadsheet_url)
    @only_flagged = only_flagged
    @workspace_id = workspace_id.presence
    raise "Google アクセストークンがありません。再度 Google ログインしてください。" if @user.google_access_token.blank? && @user.google_refresh_token.blank?
  end

  def call
    @service = Google::Apis::SheetsV4::SheetsService.new
    @service.authorization = build_auth

    spreadsheet = @service.get_spreadsheet(@spreadsheet_id)
    existing = spreadsheet.sheets.map { |s| s.properties.title }

    active_sheet = @only_flagged ? "前回/今日 (フラグ付)" : "現在のタスク"
    completed_sheet = "完了タスク"

    # シートがなければ作成
    ensure_sheet(existing, active_sheet)
    ensure_sheet(existing, completed_sheet) unless @only_flagged

    # データ取得 (only_flagged=true なら do_today || did_previous のみ)
    base = scoped_tasks
    if @only_flagged
      base = base.where("do_today = ? OR did_previous = ?", true, true)
    end
    done_tasks = base.where(status_id: 3).order(:issue_key)    # 処理済
    wip_tasks = base.where(status_id: 2).order(:issue_key)     # 処理中
    todo_tasks = base.where(status_id: 1).order(:issue_key)    # 未対応
    completed_tasks = @only_flagged ? [] : scoped_tasks.where(status_id: 4).order(completed_on: :desc)

    write_active_sheet(active_sheet, done_tasks, wip_tasks, todo_tasks)
    write_completed_sheet(completed_sheet, completed_tasks) unless @only_flagged

    { active: done_tasks.size + wip_tasks.size + todo_tasks.size, completed: completed_tasks.size }
  end

  private

  # 案件ごとに別シートへ書き出すので、ワークスペース指定があればそれで絞る
  def scoped_tasks
    @workspace_id ? @user.backlog_tasks.where(progress_workspace_id: @workspace_id) : @user.backlog_tasks
  end

  def extract_id(url)
    m = url.match(%r{/spreadsheets/d/([a-zA-Z0-9_-]+)})
    raise "スプレッドシートのURLが不正です" unless m
    m[1]
  end

  # トークンが無い操作者は admin(西野) にフォールバック
  def build_auth
    GoogleAuth.build_with_fallback(@user)
  end

  def ensure_sheet(existing, title)
    return if existing.include?(title)
    req = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(
      requests: [ { add_sheet: { properties: { title: title } } } ]
    )
    @service.batch_update_spreadsheet(@spreadsheet_id, req)
  end

  def write_active_sheet(sheet_name, done_tasks, wip_tasks, todo_tasks)
    rows = []

    # 「本日行う」は A列のチェックボックスで見えるので、色の凡例行は置かない
    rows << [ "", "本日やるタスクの A列にチェックを入れて「インポート」すると、アプリの「本日行う」に反映されます（書き出し直後は全て未チェック）" ]
    rows << []

    # ヘッダ
    rows << [ "本日行う", "タスク名", "予定開始", "予定終了", "実績開始", "実績終了", "進捗率", "担当", "備考", "id" ]
    rows << [ "", "", "", "", "", "", "20%=調査中\n40%=実装中\n60%=実装完了\n80%=エビデンス完了\n100%=完了", "", "", "" ]
    rows << []

    section_rows = [] # セクション行の位置を記録 [row_index, color_key]

    push_section = lambda do |label, color_key, tasks|
      next unless tasks.any?
      section_rows << [ rows.size, color_key ]
      rows << [ "", label ]
      tasks.each { |t| rows << task_row(t) }
      rows << []
    end

    # 完了2日以内セクション（最近完了したもの）
    recent = scoped_tasks.where(status_id: 4)
      .where("completed_on >= ?", Date.current - 2).order(completed_on: :desc)
    push_section.call("【完了（2日以内）】", :completed, recent)
    push_section.call("【処理済】", :section_done, done_tasks)
    push_section.call("【処理中】", :section_wip, wip_tasks)
    push_section.call("【未対応】", :section_todo, todo_tasks)

    write_and_format(sheet_name, rows, section_rows, header_row_offset: 2)
  end

  def write_completed_sheet(sheet_name, tasks)
    rows = []

    rows << [ "", "本日やるタスクの A列にチェックを入れて「インポート」すると、アプリの「本日行う」に反映されます（書き出し直後は全て未チェック）" ]
    rows << []

    rows << [ "本日行う", "タスク名", "予定開始", "予定終了", "実績開始", "実績終了", "進捗率", "担当", "備考", "id" ]
    rows << [ "", "", "", "", "", "", "20%=調査中\n40%=実装中\n60%=実装完了\n80%=エビデンス完了\n100%=完了", "", "", "" ]
    rows << []

    section_rows = [ [ rows.size, :completed ] ]
    rows << [ "", "【完了】" ]
    tasks.each { |t| rows << task_row(t) }

    write_and_format(sheet_name, rows, section_rows, header_row_offset: 2)
  end

  def task_row(t)
    progress = t.progress_value || t.progress
    progress_str = progress ? (progress * 100).round.to_s + "%" : ""

    title = "#{t.issue_key} #{t.summary}"
    title_cell = t.url.present? ? %(=HYPERLINK("#{t.url.to_s.gsub('"', '""')}","#{title.gsub('"', '""')}")) : title

    [
      # A: 本日行う（チェックボックス）。書き出しは常に未チェックで出し、
      #    シート上でその日にやる分だけチェックしてもらう運用にする。
      #    (アプリ側の do_today を持ち込むと、前回の分が最初から付いた状態になる)
      false,
      title_cell,                                 # B: タスク名
      t.start_date&.to_s || t.created_on&.to_s,  # C: 予定開始
      t.end_date&.to_s || t.due_date&.to_s,      # D: 予定終了
      t.created_on&.to_s,                         # E: 実績開始
      t.completed_on&.to_s,                       # F: 実績終了
      progress_str,                               # G: 進捗率
      t.assignee_name.to_s,                       # H: 担当
      t.memo.to_s,                                # I: 備考
      t.id.to_s                                   # J: id（取込の突合キー。列ごと非表示）
    ]
  end

  def write_and_format(sheet_name, rows, section_rows, header_row_offset: 0)
    # クリア
    @service.clear_values(@spreadsheet_id, "#{sheet_name}!A:J")

    # 書き込み
    range = "#{sheet_name}!A1:J#{rows.size}"
    value_range = Google::Apis::SheetsV4::ValueRange.new(range: range, values: rows)
    @service.update_spreadsheet_value(@spreadsheet_id, range, value_range, value_input_option: "USER_ENTERED")

    # シートIDを取得
    spreadsheet = @service.get_spreadsheet(@spreadsheet_id)
    sheet = spreadsheet.sheets.find { |s| s.properties.title == sheet_name }
    return unless sheet
    sheet_id = sheet.properties.sheet_id

    # 書式リクエスト
    requests = []

    # ★ まず全範囲(A:J, 0〜2000行)の書式を白でリセット
    # clear_values は値しか消さないため、過去の背景色(旧仕様の黄/ピンク/紫)が残るのを防ぐ。
    # 併せて A列の旧データ検証(チェックボックス)も消す。行数が減ったとき、
    # 前回のチェックボックスが値のない行に居残るため。
    requests << {
      repeat_cell: {
        range: {
          sheet_id: sheet_id,
          start_row_index: 0,
          end_row_index: 2000,
          start_column_index: 0,
          end_column_index: DATA_COLUMN_COUNT
        },
        cell: {
          user_entered_format: {
            background_color: COLORS[:white],
            text_format: { foreground_color: { red: 0, green: 0, blue: 0 }, bold: false }
          }
        },
        fields: "userEnteredFormat(backgroundColor,textFormat)"
      }
    }
    requests << {
      set_data_validation: {
        range: { sheet_id: sheet_id, start_row_index: 0, end_row_index: 2000, start_column_index: 0, end_column_index: 1 }
      }
    }

    # ヘッダ行に背景色
    requests << format_rows(sheet_id, header_row_offset, header_row_offset + 2, COLORS[:header_bg], true)

    # 既存フィルタをクリア
    if sheet.basic_filter
      requests << { clear_basic_filter: { sheet_id: sheet_id } }
    end

    # セクション見出し(【処理中】など)だけ黄色+太字。タスク行は白のまま。
    # 「本日行う/前回行った」の色分けは廃止(A列のチェックボックスで判別する)。
    section_rows.each_with_index do |(row_idx, _color_key), i|
      requests << format_rows(sheet_id, row_idx, row_idx + 1, COLORS[:header_bg], true)

      # 次のセクション見出しまで(なければ末尾まで)がこのセクションのタスク行
      next_start = (i + 1 < section_rows.size) ? section_rows[i + 1][0] : rows.size
      next unless next_start > row_idx + 1

      requests << format_rows(sheet_id, row_idx + 1, next_start, COLORS[:white], false)
      # A列にチェックボックスを出す(値は task_row が true/false で入れている)
      requests << {
        repeat_cell: {
          range: {
            sheet_id: sheet_id,
            start_row_index: row_idx + 1,
            end_row_index: next_start,
            start_column_index: 0,
            end_column_index: 1
          },
          cell: {
            data_validation: { condition: { type: "BOOLEAN" } },
            user_entered_format: { horizontal_alignment: "CENTER" }
          },
          fields: "dataValidation,userEnteredFormat.horizontalAlignment"
        }
      }
    end

    # B列の幅を広げる
    requests << {
      update_dimension_properties: {
        range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: 1, end_index: 2 },
        properties: { pixel_size: 400 },
        fields: "pixelSize"
      }
    }

    # I列(備考)の幅
    requests << {
      update_dimension_properties: {
        range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: 8, end_index: 9 },
        properties: { pixel_size: 300 },
        fields: "pixelSize"
      }
    }

    # A列(チェックボックス)はチェックが押せる程度の幅にする
    requests << {
      update_dimension_properties: {
        range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: 0, end_index: 1 },
        properties: { pixel_size: 70 },
        fields: "pixelSize"
      }
    }

    # J列(id)は取込の突合にだけ使う内部データなので列ごと隠す
    requests << {
      update_dimension_properties: {
        range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: ID_COLUMN_INDEX, end_index: ID_COLUMN_INDEX + 1 },
        properties: { hidden_by_user: true },
        fields: "hiddenByUser"
      }
    }

    # J列以降の余分な列を削除（データ範囲外のグリッド線・旧罫線を消す）
    grid_column_count = sheet.properties.grid_properties&.column_count.to_i
    if grid_column_count > DATA_COLUMN_COUNT
      requests << {
        delete_dimension: {
          range: { sheet_id: sheet_id, dimension: "COLUMNS", start_index: DATA_COLUMN_COUNT, end_index: grid_column_count }
        }
      }
    end

    if requests.any?
      batch = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests)
      @service.batch_update_spreadsheet(@spreadsheet_id, batch)
    end

    # フィルタを別 batch で設定（結合セルがあるとエラーになるため先に結合解除）
    filter_requests = []
    # 結合を全解除
    spreadsheet = @service.get_spreadsheet(@spreadsheet_id)
    sheet = spreadsheet.sheets.find { |s| s.properties.sheet_id == sheet_id }
    (sheet&.merges || []).each do |merge|
      filter_requests << { unmerge_cells: { range: merge } }
    end
    # フィルタ設定
    filter_requests << {
      set_basic_filter: {
        filter: {
          range: { sheet_id: sheet_id, start_row_index: header_row_offset + 2, start_column_index: 0, end_column_index: DATA_COLUMN_COUNT }
        }
      }
    }
    batch2 = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: filter_requests)
    @service.batch_update_spreadsheet(@spreadsheet_id, batch2) rescue nil
  end

  def format_rows(sheet_id, start_row, end_row, color, bold = false)
    cell_format = { background_color: color }
    cell_format[:text_format] = { bold: true } if bold

    {
      repeat_cell: {
        range: {
          sheet_id: sheet_id,
          start_row_index: start_row,
          end_row_index: end_row,
          start_column_index: 0,
          end_column_index: DATA_COLUMN_COUNT
        },
        cell: { user_entered_format: cell_format },
        fields: "userEnteredFormat(backgroundColor#{bold ? ',textFormat' : ''})"
      }
    }
  end
end
