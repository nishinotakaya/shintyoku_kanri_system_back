# 動画台本を AI 添削する。
# - 誤字脱字・不自然な日本語・テンプレ崩れを直す
# - 事実の矛盾(学歴/収入/雇用形態/「◯選」の個数 等)を検出
# - 自動で直せない曖昧な箇所は「どちらでしょうか？」と質問(選択肢つき)で返す
# answers(ユーザーの回答)を渡すと、それを正として最終版を返す。
class InterviewVideoProofreader
  def initialize(user:, script:, persona: nil, title: nil, answers: nil)
    @user = user
    @script = script.to_s
    @persona = persona.to_s
    @title = title.to_s
    @answers = answers # { "質問key" => "選んだ回答" }
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    OpenaiJson.chat_json(system: SYS, user: prompt, api_key: api_key, model: "gpt-4o", temperature: 0.2)
  end

  SYS = <<~SYS.freeze
    あなたはYouTube台本の校正者です。出演者本人が一人称で語る台本を添削します。
    次の JSON で返してください:
    {
      "issues": ["見つけた問題点を簡潔に(矛盾・誤字・テンプレ崩れ・個数不一致など)"],
      "questions": [
        { "key": "短い識別子(例: gakureki)", "question": "ユーザーに確認したい質問(例: 学歴は大卒と中卒どちらが正しいですか？)", "options": ["選択肢1","選択肢2"] }
      ],
      "corrected_script": "添削後の台本(全文)。【見出し】構成は保持。自動で直せる範囲は直す。"
    }
    【添削方針】
    - 事実の矛盾(学歴・収入・雇用形態・年収/月収・会社員/フリーランス・年齢・経歴 等)を必ずチェック。
    - **台本の隅々まで全文を走査する**。本文だけでなく、**商品名・特典名・プレゼント名・キャッチコピー・LINE誘導・概要欄文言・例え話・たとえの中**に紛れた矛盾も必ず拾う。
      例:「中卒エンジニアの実務経験獲得ロードマップ」のような特典名に、人物設定(Fラン大卒)と食い違う語(中卒)が入っていないか。1箇所でも残さない。
    - 同じ事実が複数回出てくる場合、**全ての出現箇所**を矛盾なく統一する(冒頭だけ直して後ろを残さない)。
    - **収入の表記(月収/年収/具体的な金額)は特に厳しく**チェックする。例:「月収70万円」と「年収700万円」が両方出てくるのは矛盾(両立しない)。
      ペルソナに収入が明記されていれば全箇所をそれに統一する。ペルソナで判断できない/食い違う場合は questions で
      「収入は月収◯◯ですか、年収◯◯ですか？」のように確認する。曖昧な金額表現を放置しない。
    - 「◯選」「◯つ」と予告した個数と、本編で実際に挙げた数が一致しているか確認し、ズレていたら直す。
    - 誤字脱字・不自然な言い回し・重複・冗長を整える。話し言葉は保つ。
    - 【挨拶】等の見出し構成は崩さない。意味を勝手に大きく変えない。
    - **どちらが正しいか台本だけでは断定できない事実の食い違い**は、corrected_script で仮に統一しつつ、必ず questions に「どちらでしょうか？」形式で挙げる(options に候補)。
    - issues には見逃しが無いよう、見つけた矛盾を**箇所がわかる形で具体的に**列挙する(例:「特典名『中卒エンジニア〜』が人物設定と矛盾」)。
    - ユーザーの回答(answers)が与えられている場合は、それを唯一の正として corrected_script の**全箇所**に反映し、questions は空配列にする。
  SYS

  def prompt
    parts = []
    parts << "【動画タイトル/テーマ】#{@title}" if @title.present?
    parts << "【ペルソナ・確定したい事実】\n#{@persona}" if @persona.present?
    if @answers.present?
      parts << "【ユーザーが確定した回答(これを正とする)】"
      @answers.each { |k, v| parts << "・#{k}: #{v}" }
    end
    parts << "【添削対象の台本】\n#{@script}"
    parts.join("\n")
  end
end
