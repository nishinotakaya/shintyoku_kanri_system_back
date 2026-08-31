require "test_helper"

# GoogleSheetsImporter の列検出とチェックボックス取込。
# 本アプリが書き出すシートは A=本日行う(チェック) / B=タスク名 / C〜G=日付・進捗 / J=id。
# A列が "TRUE"/"FALSE" の文字として返るため、列位置を「テキストが多い方」で
# 推測すると誤判定する。ヘッダ行で確定させていることを検証する。
class GoogleSheetsImporterLayoutTest < Minitest::Test
  def setup
    # コンストラクタが Google トークンの有無を見るのでダミーを入れる。
    # このテストは列の解釈だけを見るので、Google へは接続しない。
    @user = User.create!(
      email: "sheet_import_#{SecureRandom.hex(4)}@example.com",
      password: "password123", display_name: "取込テスト",
      google_access_token: "dummy-token"
    )
    @importer = GoogleSheetsImporter.new(user: @user, spreadsheet_url: "https://docs.google.com/spreadsheets/d/DUMMYID/edit")
  end

  def teardown
    BacklogTask.where(user_id: @user.id).delete_all
    @user.destroy
  end

  # このアプリが書き出した形のシート(先頭2行は案内+空行、3行目がヘッダ)
  def exported_rows(check: "TRUE", id: "123")
    [
      [ "", "本日行う → A列のチェックを入れる" ],
      [],
      [ "本日行う", "タスク名", "予定開始", "予定終了", "実績開始", "実績終了", "進捗率", "担当", "備考", "id" ],
      [ "", "", "", "", "", "", "20%=調査中", "", "", "" ],
      [],
      [ "", "【処理中】" ],
      [ check, "SAP-1234 テストタスク", "2026-08-01", "2026-08-10", "2026-08-02", "", "40%", "西野", "メモ", id ]
    ]
  end

  # 1. ヘッダから列を確定する（A列のTRUE/FALSEに引きずられない）
  def test_detects_columns_from_header
    layout = @importer.send(:detect_layout, exported_rows)

    title_col, plan_s, plan_e, act_s, act_e, prog_col, id_col, today_col = layout
    assert_equal 1, title_col, "タスク名はB列"
    assert_equal 2, plan_s
    assert_equal 3, plan_e
    assert_equal 4, act_s
    assert_equal 5, act_e
    assert_equal 6, prog_col
    assert_equal 9, id_col, "id は J列"
    assert_equal 0, today_col, "本日行う は A列"
  end

  # 2. 旧来の 進捗管理_西野.xlsx 形式（ヘッダに「タスク名」が無い）は従来どおり
  def test_falls_back_to_legacy_layout
    # 旧シートはA列がほぼ空で、B列に見出しとタイトルが並ぶ
    legacy = [
      [ "", "進捗管理" ],
      [ "", "タスク" ],
      [ "", "【処理中】" ],
      [ "1", "SAP-1 旧形式", "", "", "", "2026-08-01", "2026-08-10", "2026-08-02", "2026-08-05", "50%" ],
      [ "2", "SAP-2 旧形式", "", "", "", "2026-08-01", "2026-08-10", "", "", "10%" ]
    ]
    title_col, plan_s, _plan_e, _act_s, _act_e, prog_col, id_col, today_col = @importer.send(:detect_layout, legacy)

    assert_equal 1, title_col
    assert_equal 5, plan_s
    assert_equal 9, prog_col
    assert_equal 0, id_col, "旧形式は A列が id"
    assert_nil today_col, "旧形式にチェックボックス列は無い"
  end

  # 3. チェックが入っていれば do_today が true になる
  def test_imports_checked_box_as_do_today
    imported = @importer.send(:parse_and_import, exported_rows(check: "TRUE", id: ""), [])

    assert_equal 1, imported.size
    assert imported.first.do_today, "A列にチェックがあれば本日行う"
  end

  # 4. チェックを外したら false に戻る（外しても消えない、を避ける）
  def test_unchecked_box_clears_do_today
    task = @user.backlog_tasks.create!(issue_key: "SAP-1234", summary: "既存", do_today: true,
                                        status_id: 2, created_on: Date.new(2026, 8, 1))

    @importer.send(:parse_and_import, exported_rows(check: "FALSE", id: task.id.to_s), [])

    refute task.reload.do_today, "シートでチェックを外したら false に戻す"
  end

  # 5. J列の id で既存タスクを更新する（A列ではなく）
  def test_matches_existing_task_by_id_column
    task = @user.backlog_tasks.create!(issue_key: "OLD-KEY", summary: "旧タイトル",
                                        status_id: 1, created_on: Date.new(2026, 8, 1))

    imported = @importer.send(:parse_and_import, exported_rows(check: "TRUE", id: task.id.to_s), [])

    assert_equal task.id, imported.first.id, "J列の id で既存レコードに当たる"
    assert_equal "SAP-1234 テストタスク", task.reload.summary
  end
end
