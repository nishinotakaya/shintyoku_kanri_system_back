require "test_helper"

# BacklogActivitySummary: Backlog 活動(BacklogActivity)から上司報告サマリの行を組み立てるサービス。
# 「完了への状態変更が同期範囲外でも、完了日(BacklogCompletion)が確定していれば状態は完了とする」
# ロジックのテスト。
class BacklogActivitySummaryTest < Minitest::Test
  def setup
    @user = User.create!(
      email: "backlog_summary_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "活動花子"
    )
  end

  def teardown
    @user&.destroy
  end

  # 1. 完了への状態変更活動が無くても、backlog_completions に completed_on があれば
  #    status="完了" になり、done_on はその完了日になる。
  def test_status_is_done_when_completion_exists_even_without_status_activity
    create_status_activity(occurred_on: Date.new(2026, 3, 3), content: "処理中 → 処理済み", month: "2026-03")
    BacklogCompletion.create!(user: @user, issue_key: "SAP-1", completed_on: Date.new(2026, 4, 10))

    row = BacklogActivitySummary.new(@user).rows.first

    assert_equal "完了", row[:status]
    assert_equal "完了", row[:computed_status]
    assert_equal "2026-04-10", row[:done_on]
  end

  # 2. status_override="処理済み" があっても、completed_on 等から computed_status が完了なら
  #    最終的な status は「完了」になる(手入力より Backlog の事実を優先する)。
  def test_completed_status_overrides_manual_shori_override
    create_status_activity(occurred_on: Date.new(2026, 3, 3), content: "処理中 → 処理済み", month: "2026-03")
    BacklogCompletion.create!(user: @user, issue_key: "SAP-1", completed_on: Date.new(2026, 4, 10))
    BacklogSummaryNote.create!(user: @user, month: "2026-03", issue_key: "SAP-1", status_override: "処理済み")

    row = BacklogActivitySummary.new(@user).rows.first

    assert_equal "完了", row[:status]
    assert_equal "処理済み", row[:status_override]
  end

  # 3. 完了日が無い場合は従来どおり status_override が勝つ。
  def test_status_override_wins_when_not_completed
    create_status_activity(occurred_on: Date.new(2026, 3, 3), content: "処理中 → 処理済み", month: "2026-03")
    BacklogSummaryNote.create!(user: @user, month: "2026-03", issue_key: "SAP-1", status_override: "処理済み")

    row = BacklogActivitySummary.new(@user).rows.first

    assert_equal "処理済み", row[:status]
    assert_equal "処理済み", row[:computed_status]
    assert_equal "", row[:done_on]
  end

  # 4. 同じ課題が複数月にまたがっても、最新月の1行だけに集約される。
  def test_multi_month_issue_collapses_to_single_latest_month_row
    create_status_activity(occurred_on: Date.new(2026, 6, 1), content: "未対応 → 処理中", month: "2026-06")
    create_status_activity(occurred_on: Date.new(2026, 7, 1), content: "処理中 → 処理済み", month: "2026-07")

    rows = BacklogActivitySummary.new(@user).rows.select { |r| r[:issue_key] == "SAP-1" }

    assert_equal 1, rows.size, "同一課題は1行に集約されるべき"
    assert_equal "2026-07", rows.first[:month], "最新月になるべき"
    # 開始日は全活動の最早、状態は最新の状態変更から算出される
    assert_equal "2026-06-01", rows.first[:start_on]
  end

  # 5. 複数課題は最新月が新しい順に並ぶ(同月内は課題キー降順)。
  def test_issues_are_sorted_by_latest_month_desc
    create_status_activity(occurred_on: Date.new(2026, 5, 1), content: "未対応 → 処理中", month: "2026-05", issue_key: "SAP-100")
    create_status_activity(occurred_on: Date.new(2026, 7, 1), content: "未対応 → 処理中", month: "2026-07", issue_key: "SAP-200")
    create_status_activity(occurred_on: Date.new(2026, 7, 2), content: "未対応 → 処理中", month: "2026-07", issue_key: "SAP-300")

    keys = BacklogActivitySummary.new(@user).rows.map { |r| [ r[:month], r[:issue_key] ] }

    # 2026-07 が先、同月内は課題キー降順(SAP-300 → SAP-200)、最後に 2026-05
    assert_equal [ [ "2026-07", "SAP-300" ], [ "2026-07", "SAP-200" ], [ "2026-05", "SAP-100" ] ], keys
  end

  # 6. 最新月にメモが無くても、同じ課題の古い月のメモ(内容あり)を最新月の行に引き継ぐ。
  def test_note_from_older_month_is_carried_to_latest_month_row
    create_status_activity(occurred_on: Date.new(2026, 6, 1), content: "未対応 → 処理中", month: "2026-06")
    create_status_activity(occurred_on: Date.new(2026, 7, 1), content: "処理中 → 処理済み", month: "2026-07")
    BacklogSummaryNote.create!(user: @user, month: "2026-06", issue_key: "SAP-1", note: "古い月のメモ")

    row = BacklogActivitySummary.new(@user).rows.find { |r| r[:issue_key] == "SAP-1" }

    assert_equal "2026-07", row[:month]
    assert_equal "古い月のメモ", row[:note], "古い月のメモを最新月の行に引き継ぐべき"
  end

  # 7. 活動が全く無い課題の備考(資料:リンク集など)は従来どおり備考のみ行として出る。
  def test_note_only_row_without_activity_is_still_shown
    BacklogSummaryNote.create!(user: @user, month: "2026-07", issue_key: "SAP-9000", note: "資料リンク集")

    row = BacklogActivitySummary.new(@user).rows.find { |r| r[:issue_key] == "SAP-9000" }

    refute_nil row
    assert_equal "資料リンク集", row[:note]
    assert_equal "", row[:summary]
  end

  private

  def create_status_activity(occurred_on:, content:, month:, issue_key: "SAP-1")
    BacklogActivity.create!(
      user: @user,
      activity_id: rand(1_000_000..9_999_999),
      issue_key: issue_key,
      summary: "テスト課題の概要",
      activity_type: "status",
      content: content,
      occurred_on: occurred_on,
      month: month
    )
  end
end
