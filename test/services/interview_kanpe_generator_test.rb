require "test_helper"

# InterviewKanpeGenerator: マインドマップ(動画タイトル)から撮影用カンペ(cue sheet)を AI 生成するサービス。
# OpenAI へは絶対に実接続しない(OpenaiClient.api_key_for / OpenaiJson.chat_json を一時的に差し替える)。
#
# 注: このプロジェクトの minitest (v6) には Object#stub (minitest/mock) が同梱されていないため、
# 既存テスト(tax_summary_builder_consumption_tax_test.rb)に倣い、シングルトンメソッドの
# 差し替え・復元によるスタブを行う。
class InterviewKanpeGeneratorTest < Minitest::Test
  def setup
    @operator_user = User.create!(
      email: "kanpe_operator_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "操作者太郎"
    )
    @persona_user = User.create!(
      email: "kanpe_persona_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "ペルソナ花子",
      video_script_context: "元テスターから未経験でエンジニアに転身。時給1300円から3200円になった。"
    )
    @mindmap = InterviewMindmap.create!(user: @persona_user, mode: "interview", title: "未経験からエンジニアになるまで")
    @mindmap.nodes.create!(kind: "root", text: "ペルソナ花子のスキルシート", position: 0)
  end

  def teardown
    @mindmap&.destroy
    @persona_user&.destroy
    @operator_user&.destroy
  end

  # 1. call が chat_json の結果 {"kanpe" => "..."} から文字列を返す(前後の空白は除去)
  def test_call_returns_kanpe_string_from_stubbed_chat_json
    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: @mindmap)

    result = with_stubbed_method(OpenaiClient, :api_key_for, ->(*) { "dummy-api-key" }) do
      with_stubbed_method(OpenaiJson, :chat_json, ->(**) { { "kanpe" => "  生成されたカンペ本文  " } }) do
        generator.call
      end
    end

    assert_equal "生成されたカンペ本文", result
  end

  # chat_json の戻り値に kanpe キーが無い場合は空文字を返す(nil.to_s.strip)
  def test_call_returns_blank_string_when_kanpe_key_missing
    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: @mindmap)

    result = with_stubbed_method(OpenaiClient, :api_key_for, ->(*) { "dummy-api-key" }) do
      with_stubbed_method(OpenaiJson, :chat_json, ->(**) { {} }) do
        generator.call
      end
    end

    assert_equal "", result
  end

  # call が chat_json に渡す引数を検証する(system/user プロンプト・api_key・model を渡していること)
  def test_call_passes_expected_arguments_to_chat_json
    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: @mindmap)
    received_kwargs = nil

    result = with_stubbed_method(OpenaiClient, :api_key_for, ->(*) { "dummy-api-key" }) do
      with_stubbed_method(OpenaiJson, :chat_json, ->(**kwargs) { received_kwargs = kwargs; { "kanpe" => "ok" } }) do
        generator.call
      end
    end

    assert_equal "ok", result
    refute_nil received_kwargs
    assert_equal "dummy-api-key", received_kwargs[:api_key]
    assert_equal "gpt-4o", received_kwargs[:model]
    assert_includes received_kwargs[:system], "カンペ(cue sheet)"
    assert_kind_of String, received_kwargs[:user]
  end

  # 2-a. persona(mindmap.user.video_script_context) がある場合にプロンプトへ含まれる
  def test_prompt_includes_persona_video_script_context_when_present
    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: @mindmap)

    prompt = generator.send(:prompt)

    assert_includes prompt, "元テスターから未経験でエンジニアに転身。時給1300円から3200円になった。"
    assert_includes prompt, "【ペルソナ・プロフィール・事業内容"
  end

  # 2-a(edge). persona の video_script_context が空の場合はその見出し自体を含めない
  def test_prompt_omits_persona_section_when_video_script_context_blank
    persona_without_context = User.create!(
      email: "kanpe_persona_blank_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "ペルソナ空太郎"
    )
    mindmap_without_context = InterviewMindmap.create!(user: persona_without_context, mode: "interview", title: "テーマ無し")
    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: mindmap_without_context)

    prompt = generator.send(:prompt)

    refute_includes prompt, "【ペルソナ・プロフィール・事業内容"
  ensure
    mindmap_without_context&.destroy
    persona_without_context&.destroy
  end

  # 2-b. mindmap の answer ノードがプロンプトに含まれる
  def test_prompt_includes_answer_nodes_from_mindmap
    @mindmap.nodes.create!(kind: "question", text: "前職は何をしていましたか？", position: 1)
    @mindmap.nodes.create!(kind: "answer", text: "ソフトウェアテスターとして手動テストを担当していました。", position: 2)

    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: @mindmap)
    prompt = generator.send(:prompt)

    assert_includes prompt, "【マインドマップで用意した回答(参考)】"
    assert_includes prompt, "ソフトウェアテスターとして手動テストを担当していました。"
  end

  # 2-b(edge). answer ノードが無い場合は「マインドマップで用意した回答」の見出しごと出さない
  def test_prompt_omits_answers_section_when_no_answer_nodes
    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: @mindmap)
    prompt = generator.send(:prompt)

    refute_includes prompt, "【マインドマップで用意した回答(参考)】"
  end

  # 2-c. 【守るべきテンプレート構成】がプロンプトに含まれる(config/locales/prompts.ja.yml 由来)
  def test_prompt_includes_template_construction_marker
    generator = InterviewKanpeGenerator.new(user: @operator_user, mindmap: @mindmap)
    prompt = generator.send(:prompt)

    assert_includes prompt, "【守るべきテンプレート構成】"
    assert_includes prompt, "【挨拶】"
    assert_includes prompt, "【LINE誘導】"
  end

  # 3. I18n.t("prompts.kanpe.template") が翻訳欠落エラーにならず、主要見出しを含む
  def test_kanpe_template_translation_contains_major_headings
    template_text = I18n.t("prompts.kanpe.template", raise: true)

    refute_includes template_text, "translation missing"
    assert_includes template_text, "【挨拶】"
    assert_includes template_text, "【企画コール】"
    assert_includes template_text, "【本編 要点内容1】"
    assert_includes template_text, "【LINE誘導】"
  end

  private

  # 対象(module/class)のメソッドをブロックの間だけ差し替え、終了後に必ず元へ戻す。
  # OpenAI 実呼び出しをテストで避けるための最小限のスタブ(minitest v6 に minitest/mock が同梱されないため自前実装)。
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
