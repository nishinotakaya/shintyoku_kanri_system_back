# マインドマップ(動画タイトル)から、撮影中に本人がチラ見して話す「カンペ(cue sheet)」を AI 生成する。
# 台本(InterviewVideoScriptGenerator)と違い、本編の各要点は「未来/問題/原因/解決」のラベルを見せたまま書く。
# mindmap.kanpe_style で sales(西野式セールス・既定) / app_build(アプリを作る完全台本) を切り替える。
class InterviewKanpeGenerator
  # 1 回目の生成がこの字数に届かなければ、テーマ・見出しを保ったまま肉付けさせる。
  MIN_CHARS = 4000
  # 4500字以上(日本語で約 4500〜6000 トークン)を返させるため、既定の 4096 では足りない。
  MAX_TOKENS = 8000
  # 肉付けの追加リクエスト回数の上限(1回では 4000 字に届かないことが多いため)。
  EXPAND_ATTEMPTS = 2
  # 肉付けしてもこの字数しか伸びなければ頭打ちとみなして打ち切る。
  EXPAND_MIN_GROWTH = 200

  # user: OpenAIキー解決用(操作者) / mindmap: カンペの元になるマインドマップ(動画タイトル・スキルシートの持ち主)
  def initialize(user:, mindmap:)
    @user = user
    @mindmap = mindmap
    @persona_user = mindmap.user
    @sheet = mindmap.skill_sheet || @persona_user.skill_sheet || user.skill_sheet
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    kanpe = generate(prompt, api_key)
    EXPAND_ATTEMPTS.times do
      break if kanpe.size >= MIN_CHARS || kanpe.empty?

      expanded = generate(expand_prompt(kanpe), api_key)
      break if expanded.size <= kanpe.size + EXPAND_MIN_GROWTH # これ以上伸びないなら諦める

      kanpe = expanded
    end
    kanpe
  end

  private

  def generate(user_prompt, api_key)
    OpenaiJson.chat_json(
      system: sys_prompt, user: user_prompt, api_key: api_key,
      model: "gpt-4o", temperature: 0.7, max_tokens: MAX_TOKENS
    )["kanpe"].to_s.strip
  end

  # 薄いカンペを、テーマ・見出し・要点を変えずに厚くさせる追い込みプロンプト。
  def expand_prompt(thin_kanpe)
    <<~PROMPT
      次のカンペは内容は正しいものの、#{thin_kanpe.size}字しかなく撮影に使うには薄すぎます。
      テーマ・見出し・要点3つ・話の順番は一切変えずに、各セクションを具体例・あるあるのシーン・本人の体験談で肉付けし、
      全体で4500字以上に書き直してください。同じ意味の言い換えによる水増しはせず、中身のある具体を足すこと。
      特に【本編 要点内容1〜3】の「未来：」「問題：」「原因：」「解決：」は各3〜4文にすること。
      肉付けで足してはいけないもの: 学歴の話(中卒/高卒/大卒 等)、第三者の数字入り実績(「知り合いは月収50万になった」等)、
      今回のテーマから外れる別企画の話。足すのは本人の体験と、視聴者が「あるある」と感じる状況描写だけ。

      #{thin_kanpe}
    PROMPT
  end

  def youtube_mindmap? = @mindmap.respond_to?(:youtube?) && @mindmap.youtube?
  def app_build? = @mindmap.respond_to?(:app_build_kanpe?) && @mindmap.app_build_kanpe?

  # 西野式 YouTube セールス カンペテンプレート(挨拶→企画コール→本編→誘導)。
  # 本文は config/locales/prompts.ja.yml (prompts.kanpe.template) に集約。
  def self.template_text = I18n.t("prompts.kanpe.template")

  # アプリを作る完全台本テンプレート(フック→オープニング→デモ→AI時代の価値→エンジニア転職→CTA)。
  # 本文は config/locales/prompts.ja.yml (prompts.kanpe.app_build_template) に集約。
  def self.app_build_template_text = I18n.t("prompts.kanpe.app_build_template")

  def sys_prompt
    return app_build_sys_prompt if app_build?
    <<~SYS
      あなたはYouTube動画のセールス構成作家です。撮影中に本人がチラ見して話すための『カンペ(cue sheet)』を作ります。
      次の JSON で返してください: { "kanpe": "カンペ全文" }
      【出力フォーマット】
      - 次の【見出し】で必ず区切る(この見出し文字列は固定。フロントがこれでパースする):
        【挨拶】【企画コール】【大きな問題定義】【具体例】【最悪の未来】【ベネフィット】【ターゲット指定】【自己紹介】【要点まとめ】
        【本編 要点内容1】【本編 要点内容2】【本編 要点内容3】【最終まとめ】【LINE誘導】【アウトプット誘導】
      - 【本編 要点内容1】〜【本編 要点内容3】は、見出しの直後の行に「◯◯(お題名)」を書き、続けて
        「未来：」「問題：」「原因：」「解決：」のラベル付きの段落で書く(台本と違い、カンペではラベルを見せる)。
      【最重要: テーマの一貫性】
      - カンペ全体(企画コール・大きな問題定義・具体例・要点まとめ・本編の要点3つ・最終まとめ)は、
        必ず【動画タイトル/テーマ】の内容に直結させる。要点3つはタイトルから導く
        (例: タイトルが「もう遅いと言われて私がエンジニアになるまで」なら、
         要点は「なぜ『もう遅い』と言われるのか」「遅いと言われた自分が実際どう乗り越えたか」「今から始めても間に合う理由と戦略」のように、タイトルの言葉に紐づける)。
      - 【企画コール】は【動画タイトル/テーマ】の言葉を使って宣言する
        (「今回の企画は「〈タイトルの内容〉」について話していきます」)。参考資料にある別の企画名を名乗らない。
      - ただしタイトル冒頭の【元介護士】のような角括弧のラベルはサムネ用なので読み上げない。
        【声に出すときのテーマ表現】がある場合はそれを使い、無ければ角括弧を外して自然な話し言葉にする。
      - ペルソナや参考資料の中に過去の台本・例文が含まれていても、そのテーマや要点(教材の使い方・企業が求める人材 等)を
        そのまま流用しない。ペルソナは「名乗り・経歴・数字・実績」の事実の出典としてだけ使う。
      - 参考資料の文をコピペしない。無料プレゼント名・具体例・まとめの一文も、今回のタイトルに合わせて書き下ろす。
      - 出力前に自己チェック: 企画コール・要点3つ・最終まとめが、タイトルを読んだ人が期待する内容になっているか。
        なっていなければ書き直す。
      【スタイル】
      - 本文は本人がそのまま声に出して読める自然な話し言葉(です・ます)にする。
      - 【挨拶】と【自己紹介】では必ず本人の名前(【出演者】に書かれた名前)をフルネームで名乗る
        (例:「〜になった西野鷹也です」「改めて自己紹介すると、西野鷹也と申します」)。名前を省略した自己紹介にしない。
      - 事実(経歴・数字)はペルソナ/スキルシートにある範囲のみ使う。創作しない。台本全体で矛盾させない。
      - 【学歴は絶対に創作しない】中卒/高卒/大卒などの学歴は、出典(ペルソナ/スキルシート)に明記が無い限り一切書かない・推測しない。
        前職や経歴は出典にある事実(例: 前職＝介護職)だけを使う。学歴の記載が無いなら「前職(例: 介護職)からエンジニアを目指し」のように経歴で語る。
        参考資料(過去台本)に学歴の表現があっても、資料内で食い違っていることがあるので引用しない。プレゼント名など固有名詞に学歴語が入っている場合も言い換える。
      - 相談者・知人など第三者の話は、数字入りの実績(「月収50万円になった」等)を創作しない。状況・悩みの描写にとどめる。
      - 「◯つのポイント」と予告したら、本編でその個数ぴったりを扱う(3と言ったら3つ)。
      【分量(必達)】
      - 全体で必ず4500字以上(目安4500〜6000字)。短く終わらせない。字数が不足するなら本編要点や具体例を足して必ず4500字以上にする。
      - 各【見出し】の本文は最低3文以上。単語だけ・1文だけの薄いセクションにしない。
      - 特に【本編 要点内容1〜3】は最重要: 「未来：」「問題：」「原因：」「解決：」の各ラベルを必ず3〜4文で、
        具体例・あるあるのシーン・本人の体験談を交えて厚く語る(各本編要点は300字以上)。
      - ただし同じ内容の水増し・繰り返しは禁止。中身のある具体で字数を満たす。
    SYS
  end

  def app_build_sys_prompt
    <<~SYS
      あなたはYouTube教育系動画の構成作家です。「AIツールでアプリをゼロから作って見せる」動画の撮影用完全台本を作ります。
      次の JSON で返してください: { "kanpe": "台本全文" }
      【出力フォーマット】
      - 次の【見出し】で必ず区切る(この見出し文字列は固定。フロントがこれでパースする):
        【フック】【オープニング】【ツール説明】【デモ準備】【デモ お願いする】【デモ AIが作る様子】【デモ 完成・動作確認】【AI時代の価値】【エンジニア転職への繋げ方】【今日からの3ステップ+CTA】【デモ用プロンプト】
      - 各セクションの本文は、本人がそのまま声に出して読めるセリフを「」で書く。
      - セリフの合間に、`> 【画面】...` `> 【テロップ】...` の形式で演出指示行を入れる(行頭を > にする)。
      【最重要: テーマの一貫性】
      - 台本全体は必ず【動画タイトル/テーマ】の内容に直結させる。デモ題材はタイトルとマインドマップから導く。
      - ペルソナや参考資料に過去の台本があっても、そのテーマをそのまま流用しない。ペルソナは「名乗り・経歴・数字・実績」の事実の出典としてだけ使う。
      【スタイル】
      - 煽らない。「まだAIだけで完璧なわけではない」と正直に言う。等身大のトーン。
      - 【オープニング】では必ず本人のフルネームを名乗る。事実(経歴・数字)はペルソナ/スキルシートにある範囲のみ。創作しない。
      - 【学歴は絶対に創作しない】中卒/高卒/大卒などの学歴は出典に明記が無い限り書かない・推測しない。経歴は出典の事実(例: 前職＝介護職)だけを使う。
      - 専門用語は避け、プログラミング未経験者に伝わる言葉で。
      【分量】
      - 全体で5000〜6500字。デモの3セクション(お願いする/AIが作る様子/完成・動作確認)を最も厚くする。
    SYS
  end

  def prompt
    parts = []
    parts << "【出演者】#{@persona_user.display_name}"
    parts << "【動画タイトル/テーマ(この動画で話す内容。要点3つは必ずここから導く)】#{@mindmap.title}"
    parts << "【声に出すときのテーマ表現】#{spoken_theme}" if spoken_theme != @mindmap.title.to_s.strip
    if (persona_block = PersonaContext.new(@persona_user.video_script_context).prompt_block)
      parts << persona_block
    end
    parts << "【スキルシート(事実の出典)】\n#{sheet_summary}"
    if youtube_mindmap? && (research = YoutubeResearchReader.cached_summary).present?
      parts << "【YouTubeリサーチ】\n#{research}"
    end
    answers = @mindmap.nodes.where(kind: "answer").order(:position).limit(8).pluck(:text).reject(&:blank?)
    parts << "【マインドマップで用意した回答(参考)】\n#{answers.map { |a| "・#{a}" }.join("\n")}" if answers.any?
    template_text = app_build? ? self.class.app_build_template_text : self.class.template_text
    parts << "\n【守るべきテンプレート構成】\n#{template_text}"
    parts << "\n上記テンプレート構成に沿って、動画タイトルのテーマで本人が読むカンペを作ってください。"
    parts.join("\n")
  end

  # タイトル冒頭の【元介護士】等はサムネ用のラベルなので、読み上げ用のテーマからは外す。
  def spoken_theme
    @spoken_theme ||= @mindmap.title.to_s.gsub(/【[^】]*】/, "").gsub(/[｜|]/, " ").squeeze(" ").strip
  end

  def sheet_summary
    return "（スキルシート情報なし）" unless @sheet
    lines = []
    lines << "得意技術: #{@sheet.skills}" if @sheet.skills.present?
    lines << "自己PR: #{@sheet.self_pr.to_s.slice(0, 500)}" if @sheet.self_pr.present?
    lines.join("\n").presence || "（スキルシート情報なし）"
  end
end
