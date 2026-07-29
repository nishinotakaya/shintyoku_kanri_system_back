require "test_helper"

# PersonaContext: 設定の「ペルソナ・事業内容」をプロンプト用ブロックに整える。
# 過去台本が丸ごと貼られている場合に「軸にせよ」と渡さないことが要点。
class PersonaContextTest < Minitest::Test
  PAST_SCRIPT = <<~TEXT.freeze
    なぜ独学ではエンジニアになれないのか- YouTube台本
    挨拶 こんにちは、元月収13万円の介護士から月収70万円のエンジニアになった西野です。
    企画コール 今回の企画は「独学でエンジニアになることができない理由5選」について話していきます。
    大きな問題定義 独学でエンジニアを目指す人の9割以上が挫折しているんです。
    要点内容1：プログラミング教材の目的
    LINE誘導 プロアカの公式LINEでは〜
  TEXT

  PROFILE = "元介護士。月収13万円からエンジニアに転身し、現在は月収70万円のフリーランス。プロアカを運営。"

  def test_blank_context_returns_nil_block
    assert_nil PersonaContext.new(nil).prompt_block
    assert_nil PersonaContext.new("   ").prompt_block
  end

  def test_plain_profile_is_treated_as_persona_axis
    context = PersonaContext.new(PROFILE)

    refute context.past_script?
    assert_includes context.prompt_block, "【ペルソナ・プロフィール・事業内容"
    assert_includes context.prompt_block, PROFILE
  end

  def test_past_script_is_demoted_to_reference_material
    context = PersonaContext.new(PAST_SCRIPT)

    assert context.past_script?
    block = context.prompt_block
    assert_includes block, "【参考資料: 本人の過去動画の台本"
    refute_includes block, "最重要。これを軸に語らせる"
    assert_includes block, "流用は禁止"
    assert_includes block, "独学でエンジニアになることができない理由5選" # 本文自体は事実の出典として残す
  end

  # マーカーが2つ以下なら台本とはみなさない(普通のプロフィール文を誤判定しない)
  def test_few_markers_are_not_past_script
    refute PersonaContext.new("#{PROFILE} 台本作りが得意で、企画コールも自分で書きます。").past_script?
  end
end
