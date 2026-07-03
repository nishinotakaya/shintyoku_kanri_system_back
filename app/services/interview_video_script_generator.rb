# マインドマップ(または自由テーマ)から、アバターに喋らせるインタビュー台本を AI 生成する。
# 本人が一人称でカメラに語る、YouTube インタビューの語り口。
class InterviewVideoScriptGenerator
  # user: OpenAIキー解決用(操作者) / persona_user: 台本の主役(ペルソナ・スキルシートの持ち主)
  # target_minutes: 0.5(ショート30秒) / 1(ショート60秒) / 5 / 10 / nil(=ランダムに5か10)
  ALLOWED_MINUTES = [ 0.5, 1, 5, 10 ].freeze
  def initialize(user:, mindmap: nil, topic: nil, persona_user: nil, target_minutes: nil)
    @user = user
    @persona_user = persona_user || mindmap&.user || user
    @mindmap = mindmap
    @topic = topic.presence
    @sheet = mindmap&.skill_sheet || @persona_user.skill_sheet || user.skill_sheet
    m = target_minutes.to_f
    @target_minutes = ALLOWED_MINUTES.include?(m) ? m : [ 5, 10 ].sample
  end

  def short? = @target_minutes <= 1

  attr_reader :target_minutes

  def call
    api_key = OpenaiClient.api_key_for(@user)
    OpenaiJson.chat_json(system: sys_prompt, user: prompt, api_key: api_key, model: "gpt-4o", temperature: 0.7)["script"].to_s.strip
  end

  private

  def youtube_mindmap? = @mindmap&.respond_to?(:youtube?) && @mindmap.youtube?

  # 西野式 YouTube セールス台本テンプレート(挨拶→企画コール→本編→誘導)。
  # 本文は config/locales/prompts.ja.yml (prompts.video_script.template) に集約。
  def self.template_text = I18n.t("prompts.video_script.template")

  # ショート(YouTube Shorts/TikTok 想定): 強い掴み→刺さる一言→CTA。テンプレ見出しは使わない。
  def short_sys_prompt
    chars = @target_minutes == 1 ? "250〜340字" : "110〜150字"
    <<~SYS
      あなたはYouTube Shorts/TikTok のショート動画の構成作家です。出演者本人が一人称でテンポよく語る、
      約#{(@target_minutes * 60).to_i}秒の短い台本を作ります。次の JSON で返してください: { "script": "台本(全文)" }
      【構成】見出しは付けない。次の流れを自然な話し言葉で:
        1) 最初の1〜2秒で心をつかむ強いフック(問いかけ or 断言)。「！」で勢いを。
        2) 一番刺さる要点を1つだけ、具体的に言い切る(複数詰め込まない)。
        3) 最後に短いCTA(「続きは公式LINEで」「コメントで教えて」等)。
      【スタイル】
      - 一人称・話し言葉・テンポ重視。短い文を畳みかける。冗長な前置きゼロ。
      - 事実(ペルソナ/スキルシート)にもとづく。数字・経歴は創作しない。台本全体で矛盾させない。
      - 強調は「！」、間は「。。。」(スペースは間にならない)。
      【分量】#{chars}に収める。これより長くしない。
    SYS
  end

  # 5分 ≈ 1500字、10分 ≈ 3000字(日本語の自然な読み上げ ≈ 300字/分)を目安にする
  def sys_prompt
    return short_sys_prompt if short?
    chars = @target_minutes == 10 ? "3400〜4400字" : "1900〜2500字"
    <<~SYS
      あなたはYouTube動画のセールス構成作家です。出演者本人がカメラに向かって一人称で語る台本を、
      指定の「テンプレート構成」に厳密に沿って作ります。
      次の JSON で返してください: { "script": "台本(全文)" }
      【出力フォーマット】
      - テンプレートの各セクションを 【挨拶】【企画コール】…【アウトプット誘導】 のように 【見出し】 を付けて区切る。
        ※この【見出し】は構成の目印で、読み上げ時には自動で除去される。だから見出しに頼らず、本文だけで意味が通るようにする。
      - 各見出しの下には「本人が実際に声に出して言う話し言葉」だけを書く。「未来：」「問題：」のようなラベルは本文に書かない。
      - 本編の各要点は、まず何の話かを主語(お題)を入れて自然に切り出す。
        例:「1つ目のポイントは、◯◯についてです。」「次に2つ目、◯◯の話をします。」
        そのうえで 未来→問題→原因→解決 の順を、ラベルを付けずに自然な文章の流れで語る。
      【スタイル】
      - 出演者本人の一人称。自然な話し言葉(です・ます／たまに口語)。教科書的・箇条書き的にしない。
      - 事実(スキルシート/テーマ/ペルソナ)にもとづく。経歴や数字は創作せず、ある範囲で。無い数字は断定しない。
      - 挨拶は経歴のギャップを活かしたインパクトのある一文にする。
      - YouTubeらしくテンポよく。掴みや強調したい所は「！」を使って勢いを出す
        (例:「はい！みなさんこんにちは！」「これ、めちゃくちゃ大事です！」)。「！」は強調の合図として使う(字幕でハイライトされる)。全文を！だらけにはしない。
      - 「間(ま)」を作りたい所には「。。。」を入れる(例:「ここ、めちゃくちゃ大事なんですけど。。。実は」)。掴みの後・重要な一言の前・問いかけの後などに効果的に。※スペースでは間にならないので必ず「。。。」。多用しない。
      【一貫性(重要)】
      - 学歴・職歴・収入・雇用形態などの事実は台本全体で必ず一致させる(冒頭と後半で食い違わせない)。
        ペルソナとテンプレ例で食い違う場合は必ず【ペルソナ】の事実を優先し、例の数字は使わない。
      - 「◯選」「◯つのポイント」と予告したら、本編でその個数ぴったりを扱う(3と言ったら3つ、5なら5つ)。
      【分量(重要)】
      - 話して約#{@target_minutes}分になるボリューム(日本語で#{chars}程度)。この字数に収める。
      - 本編の各要点は具体例・体験談を入れて厚みを出す。水増しの繰り返しはしない。
      - 字数内に収めるため内容を削る場合は、文や段落の途中で切らず、必ずセクション(見出し)単位でキリ良く完結させる。
        最後は必ず【アウトプット誘導】まで到達して締めること。
    SYS
  end

  def prompt
    parts = []
    parts << "【出演者】#{@persona_user.display_name}"
    parts << "【動画タイトル/テーマ】#{@topic || @mindmap&.title}" if @topic || @mindmap&.title
    if @persona_user.video_script_context.present?
      parts << "【ペルソナ・プロフィール・事業内容(最重要。これを軸に語らせる)】\n#{@persona_user.video_script_context}"
    end
    parts << "【スキルシート(事実の出典)】\n#{sheet_summary}"
    if youtube_mindmap? && (research = YoutubeResearchReader.cached_summary).present?
      parts << "【YouTubeリサーチ(高再生の傾向・IT副業/プログラミング。話の切り口・掴みの参考にする。事実は創作しない)】\n#{research}"
    end
    if @mindmap
      answers = @mindmap.nodes.where(kind: "answer").order(:position).limit(8).pluck(:text).reject(&:blank?)
      parts << "【マインドマップで用意した回答(参考)】\n#{answers.map { |a| "・#{a}" }.join("\n")}" if answers.any?
    end
    if short?
      parts << "\n上記をもとに、テーマに沿ったショート動画の台本(フック→要点1つ→CTA)を作ってください。"
    else
      parts << "\n【守るべきテンプレート構成】\n#{self.class.template_text}"
      parts << "\n上記のテンプレート構成に沿って、動画タイトルのテーマで本人が語る台本を作ってください。"
    end
    parts.join("\n")
  end

  def sheet_summary
    return "（スキルシート情報なし）" unless @sheet
    lines = []
    lines << "得意技術: #{@sheet.skills}" if @sheet.skills.present?
    lines << "自己PR: #{@sheet.self_pr.to_s.slice(0, 500)}" if @sheet.self_pr.present?
    lines.join("\n").presence || "（スキルシート情報なし）"
  end
end
