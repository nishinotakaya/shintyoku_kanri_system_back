# マインドマップ(動画タイトル)から、撮影中に本人がチラ見して話す「カンペ(cue sheet)」を AI 生成する。
# 台本(InterviewVideoScriptGenerator)と違い、本編の各要点は「未来/問題/原因/解決」のラベルを見せたまま書く。
class InterviewKanpeGenerator
  # user: OpenAIキー解決用(操作者) / mindmap: カンペの元になるマインドマップ(動画タイトル・スキルシートの持ち主)
  def initialize(user:, mindmap:)
    @user = user
    @mindmap = mindmap
    @persona_user = mindmap.user
    @sheet = mindmap.skill_sheet || @persona_user.skill_sheet || user.skill_sheet
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    OpenaiJson.chat_json(system: sys_prompt, user: prompt, api_key: api_key, model: "gpt-4o", temperature: 0.7)["kanpe"].to_s.strip
  end

  private

  def youtube_mindmap? = @mindmap.respond_to?(:youtube?) && @mindmap.youtube?

  # 西野式 YouTube セールス カンペテンプレート(挨拶→企画コール→本編→誘導)。
  # 本文は config/locales/prompts.ja.yml (prompts.kanpe.template) に集約。
  def self.template_text = I18n.t("prompts.kanpe.template")

  def sys_prompt
    <<~SYS
      あなたはYouTube動画のセールス構成作家です。撮影中に本人がチラ見して話すための『カンペ(cue sheet)』を作ります。
      次の JSON で返してください: { "kanpe": "カンペ全文" }
      【出力フォーマット】
      - 次の【見出し】で必ず区切る(この見出し文字列は固定。フロントがこれでパースする):
        【挨拶】【企画コール】【大きな問題定義】【具体例】【最悪の未来】【ベネフィット】【ターゲット指定】【自己紹介】【要点まとめ】
        【本編 要点内容1】【本編 要点内容2】【本編 要点内容3】【最終まとめ】【LINE誘導】【アウトプット誘導】
      - 【本編 要点内容1】〜【本編 要点内容3】は、見出しの直後の行に「◯◯(お題名)」を書き、続けて
        「未来：」「問題：」「原因：」「解決：」のラベル付きの段落で書く(台本と違い、カンペではラベルを見せる)。
      【スタイル】
      - 本文は本人がそのまま声に出して読める自然な話し言葉(です・ます)にする。
      - 【挨拶】と【自己紹介】では必ず本人の名前(【出演者】に書かれた名前)をフルネームで名乗る
        (例:「〜になった西野鷹也です」「改めて自己紹介すると、西野鷹也と申します」)。名前を省略した自己紹介にしない。
      - 事実(経歴・数字)はペルソナ/スキルシートにある範囲のみ使う。創作しない。台本全体で矛盾させない。
      - 「◯つのポイント」と予告したら、本編でその個数ぴったりを扱う(3と言ったら3つ)。
      【分量】
      - 全体で3200〜4200字に収める。
      - 特に【本編 要点内容1〜3】は厚めに: 「未来：」「問題：」「原因：」「解決：」の各段落を2〜4文にして、
        具体例・あるあるのシーン・体験談を交えてしっかり語る(1文だけの薄い段落にしない)。水増しの繰り返しはしない。
    SYS
  end

  def prompt
    parts = []
    parts << "【出演者】#{@persona_user.display_name}"
    parts << "【動画タイトル/テーマ】#{@mindmap.title}"
    if @persona_user.video_script_context.present?
      parts << "【ペルソナ・プロフィール・事業内容(最重要。これを軸に語らせる)】\n#{@persona_user.video_script_context}"
    end
    parts << "【スキルシート(事実の出典)】\n#{sheet_summary}"
    if youtube_mindmap? && (research = YoutubeResearchReader.cached_summary).present?
      parts << "【YouTubeリサーチ】\n#{research}"
    end
    answers = @mindmap.nodes.where(kind: "answer").order(:position).limit(8).pluck(:text).reject(&:blank?)
    parts << "【マインドマップで用意した回答(参考)】\n#{answers.map { |a| "・#{a}" }.join("\n")}" if answers.any?
    parts << "\n【守るべきテンプレート構成】\n#{self.class.template_text}"
    parts << "\n上記テンプレート構成に沿って、動画タイトルのテーマで本人が読むカンペを作ってください。"
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
