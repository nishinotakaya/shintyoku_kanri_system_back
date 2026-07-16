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
