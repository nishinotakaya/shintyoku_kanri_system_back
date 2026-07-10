require "test_helper"

# BacklogToSkillSheetProjectBuilder: 対応ログ(Backlog活動+Notionタスク)からスキルシートの
# 職務経歴(案件)を1件 AI 生成して保存するサービス。
# OpenAI へは絶対に実接続しない(OpenaiClient.api_key_for / OpenaiJson.chat_json を一時的に差し替える)。
class BacklogToSkillSheetProjectBuilderTest < Minitest::Test
  def setup
    @operator_user = User.create!(
      email: "backlog_builder_operator_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "操作者太郎"
    )
    @target_user = User.create!(
      email: "backlog_builder_target_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "山田 太郎"
    )
    @skill_sheet = @target_user.create_skill_sheet!(engineer_name: @target_user.display_name)
  end

  def teardown
    @skill_sheet&.destroy
    @target_user&.destroy
    @operator_user&.destroy
  end

  # 1. 対応ログが1件も無ければ例外を投げる
  def test_call_raises_when_no_activities
    builder = BacklogToSkillSheetProjectBuilder.new(skill_sheet: @skill_sheet, user: @operator_user)

    error = assert_raises(RuntimeError) { builder.call }
    assert_includes error.message, "対応ログがありません"
  end

  # 2. 期間は対応ログの実日付(min/max)から算出される("YYYY年M月")。AI が返した値ではなく計算値を優先する。
  def test_call_uses_computed_period_not_ai_output
    create_activity(occurred_on: Date.new(2025, 11, 3), month: "2025-11")
    create_activity(occurred_on: Date.new(2026, 2, 20), month: "2026-02")

    builder = BacklogToSkillSheetProjectBuilder.new(skill_sheet: @skill_sheet, user: @operator_user)

    project = with_stubbed_method(OpenaiClient, :api_key_for, ->(*) { "dummy-api-key" }) do
      with_stubbed_method(OpenaiJson, :chat_json, ->(**) { ai_response.merge("period_from" => "無視されるべき値", "period_to" => "無視されるべき値") }) do
        builder.call
      end
    end

    assert_equal "2025年11月", project[:period_from]
    assert_equal "2026年2月", project[:period_to]
  end

  # 2-b. 最終の対応ログが当月であれば period_to は「現在」になる
  def test_call_sets_period_to_gennzai_when_latest_activity_is_current_month
    create_activity(occurred_on: Date.new(2026, 1, 5), month: "2026-01")
    create_activity(occurred_on: Date.current, month: Date.current.strftime("%Y-%m"))

    builder = BacklogToSkillSheetProjectBuilder.new(skill_sheet: @skill_sheet, user: @operator_user)

    project = with_stubbed_method(OpenaiClient, :api_key_for, ->(*) { "dummy-api-key" }) do
      with_stubbed_method(OpenaiJson, :chat_json, ->(**) { ai_response }) do
        builder.call
      end
    end

    assert_equal "現在", project[:period_to]
  end

  # 3. 生成された案件は source="backlog" で保存され、既存案件の position 最大+1 になる
  def test_call_creates_project_with_backlog_source_and_next_position
    @skill_sheet.projects.create!(position: 0, title: "既存案件")
    create_activity(occurred_on: Date.new(2026, 3, 1), month: "2026-03")

    builder = BacklogToSkillSheetProjectBuilder.new(skill_sheet: @skill_sheet, user: @operator_user)

    project = with_stubbed_method(OpenaiClient, :api_key_for, ->(*) { "dummy-api-key" }) do
      with_stubbed_method(OpenaiJson, :chat_json, ->(**) { ai_response }) do
        builder.call
      end
    end

    created = @skill_sheet.projects.reload.find_by(title: "進捗管理システムの開発運用保守")
    refute_nil created
    assert_equal "backlog", created.source
    assert_equal 1, created.position
    assert_equal project[:id], created.id
  end

  private

  def create_activity(occurred_on:, month:, activity_type: "comment", issue_key: "SAP-#{rand(1000..9999)}")
    BacklogActivity.create!(
      user: @target_user,
      activity_id: rand(1_000_000..9_999_999),
      issue_key: issue_key,
      summary: "テスト課題の概要",
      activity_type: activity_type,
      content: "対応内容のテキスト",
      occurred_on: occurred_on,
      month: month
    )
  end

  def ai_response
    {
      "title" => "進捗管理システムの開発運用保守",
      "description" => "・機能Aを実装した\n・不具合Bを修正した",
      "role_scale" => "開発担当 / チーム2名",
      "languages" => "Ruby\nJavaScript",
      "db" => "MySQL",
      "server_os" => "AWS",
      "tools" => "Ruby on Rails\nGit",
      "phases" => "詳細設計\n実装\nテスト"
    }
  end

  # 対象(module/class)のメソッドをブロックの間だけ差し替え、終了後に必ず元へ戻す。
  # OpenAI 実呼び出しをテストで避けるための最小限のスタブ(InterviewKanpeGeneratorTest と同じ手法)。
  def with_stubbed_method(receiver, method_name, replacement)
    original_method = receiver.method(method_name)
    receiver.define_singleton_method(method_name) do |*args, **kwargs, &block|
      replacement.call(*args, **kwargs, &block)
    end
    yield
  ensure
    receiver.define_singleton_method(method_name, original_method)
  end
end
