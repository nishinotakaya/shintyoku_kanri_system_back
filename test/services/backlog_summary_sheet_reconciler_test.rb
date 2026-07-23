require "test_helper"

# BacklogSummarySheetReconciler: 上司報告サマリのシート行から「削除すべき対象ユーザー本人の古い行」を
# 判定する純粋クエリ。他ユーザーの行・資料行・現行サマリにある行は絶対に消さないことを検証する。
class BacklogSummarySheetReconcilerTest < Minitest::Test
  # 1行目=凡例, 2行目=ヘッダ, 3行目〜データ という実テンプレートを模したシート。
  HEADER_INDEX = 1

  def build(rows_after_header, app_pairs:, target_name: "川村 卓也")
    sheet_rows = [
      [ "凡例", "", "", "", "", "", "", "", "" ],
      [ "月", "課題", "概要", "状態推移", "開始日", "処理済日", "完了日", "備考", "担当者" ]
    ] + rows_after_header
    BacklogSummarySheetReconciler.new(
      sheet_rows: sheet_rows, header_index: HEADER_INDEX,
      app_pairs: app_pairs, target_name: target_name
    )
  end

  # 課題セル(=HYPERLINK 式でも素のキーでも)から課題キーを取り出せる想定で行を組む。
  def row(month, issue_key, assignee, note = "")
    [ month, issue_key, "概要", "処理中", "2026-01-01", "", "", note, assignee ]
  end

  # 1. 対象ユーザー本人の担当で、現行サマリに無い古い月の行は削除対象。
  def test_stale_row_of_target_user_is_deleted
    reconciler = build(
      [ row("2026-05", "SAP-3662", "川村卓也") ], # app に無い月
      app_pairs: [ [ "2026-07", "SAP-3662" ] ]      # 現行は 2026-07 だけ
    )
    assert_equal [ 2 ], reconciler.stale_row_indices # 0-based: ヘッダ2行の次
  end

  # 2. 現行サマリにある行は残す(削除しない)。
  def test_current_row_is_kept
    reconciler = build(
      [ row("2026-07", "SAP-3662", "川村卓也") ],
      app_pairs: [ [ "2026-07", "SAP-3662" ] ]
    )
    assert_empty reconciler.stale_row_indices
  end

  # 3. 他ユーザー(西野)の行は、現行サマリに無くても絶対に削除しない。
  def test_other_users_row_is_never_deleted
    reconciler = build(
      [ row("2026-05", "SAP-9999", "西野 鷹也") ],
      app_pairs: [ [ "2026-07", "SAP-3662" ] ]
    )
    assert_empty reconciler.stale_row_indices
  end

  # 4. 担当者名のスペース有無は無視して本人判定する("川村 卓也" 表示名 vs "川村卓也" 実担当)。
  def test_assignee_name_matched_ignoring_whitespace
    reconciler = build(
      [ row("2026-05", "SAP-3662", "川村卓也") ],
      app_pairs: [],
      target_name: "川村 卓也"
    )
    assert_equal [ 2 ], reconciler.stale_row_indices
  end

  # 5. 課題キーの無い行(資料:リンク集など)は削除対象外。
  def test_note_only_row_without_issue_key_is_kept
    reconciler = build(
      [ [ "2026-05", "資料:家歴", "", "", "", "", "", "リンク集", "川村卓也" ] ],
      app_pairs: []
    )
    assert_empty reconciler.stale_row_indices
  end

  # 6. 担当者が空の行は(本人と断定できないので)安全側で残す。
  def test_row_with_blank_assignee_is_kept
    reconciler = build(
      [ row("2026-05", "SAP-3662", "") ],
      app_pairs: []
    )
    assert_empty reconciler.stale_row_indices
  end

  # 7. 複数の削除対象は降順(大きい index が先)で返す(上から消すと下の行がずれるため)。
  def test_multiple_stale_rows_returned_in_descending_order
    reconciler = build(
      [
        row("2026-01", "SAP-3662", "川村卓也"),
        row("2026-02", "SAP-3662", "川村卓也"),
        row("2026-03", "SAP-3662", "川村卓也"),
        row("2026-07", "SAP-3662", "川村卓也") # これは現行サマリにある=残す
      ],
      app_pairs: [ [ "2026-07", "SAP-3662" ] ]
    )
    # 0-based index: 2,3,4 が古い月。5 は現行なので残す。降順で返る。
    assert_equal [ 4, 3, 2 ], reconciler.stale_row_indices
  end

  # 8. HYPERLINK 式のセルからも課題キーを抽出して判定できる。
  def test_hyperlink_formula_cell_is_matched
    hyperlink = %Q(=HYPERLINK("https://example.backlog.com/view/SAP-3662","SAP-3662"))
    reconciler = build(
      [ [ "2026-05", hyperlink, "概要", "処理中", "", "", "", "", "川村卓也" ] ],
      app_pairs: []
    )
    assert_equal [ 2 ], reconciler.stale_row_indices
  end

  # 9. target_name が空なら何も削除しない(安全弁)。
  def test_blank_target_name_deletes_nothing
    reconciler = build(
      [ row("2026-05", "SAP-3662", "川村卓也") ],
      app_pairs: [],
      target_name: ""
    )
    assert_empty reconciler.stale_row_indices
  end
end
