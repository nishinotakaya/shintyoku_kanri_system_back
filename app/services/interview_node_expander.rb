# 面談対策マインドマップのノードを AI で1段階展開する。
# - root      → 想定質問(questions[]) を予測
# - question  → { answer(端的回答), keywords[], followups[] }
# - followup  → question と同じ
# - answer    → 回答を受けた深掘り質問(followups[])。モテは言い回しバリエーション(answer[])
# 返り値: [{ kind:, text: }, ...]（呼び出し側で DB 保存）
class InterviewNodeExpander
  def initialize(mindmap:, node:, user:)
    @mindmap = mindmap
    @node = node
    @user = user # OpenAI APIキー解決用(操作者)
    @sheet = mindmap.skill_sheet || mindmap.user.skill_sheet
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    case @node.kind
    when "root"
      if youtube?
        # 動画タイトル/テーマに沿った想定質問を AI で生成する（タイトルとズレないように）。
        # 既出があれば重複しない追加質問を作り、失敗時のみ固定バンク(12問)にフォールバック。
        existing = @node.children.where(kind: "question").pluck(:text)
        data = OpenaiJson.chat_json(system: YOUTUBE_ROOT_SYS, user: youtube_root_prompt(existing), api_key: api_key, model: "gpt-4o", temperature: 0.7)
        questions = Array(data["questions"]).first(12).map { |q| { kind: "question", text: q.to_s } }.reject { |c| c[:text].strip.empty? }
        questions.presence || InterviewMindmap::YOUTUBE_QUESTIONS.map { |q| { kind: "question", text: q } }
      elsif mote?
        existing = @node.children.where(kind: "question").pluck(:text)
        if existing.empty?
          # 最初は固定の「相手のセリフ(Q)」を起点に並べる(返しAはQを展開すると出る/取込で同時投入)
          InterviewMindmap::MOTE_DIALOGUES.map { |d| { kind: "question", text: d[:q] } }
        else
          # 再展開: 既出と重複しない新しい「相手のセリフ」を AI で追加
          data = OpenaiJson.chat_json(system: MOTE_CAT_SYS, user: mote_category_prompt(existing), api_key: api_key, model: "gpt-4o", temperature: 0.9)
          Array(data["categories"]).first(6).map { |c| { kind: "question", text: c.to_s } }.reject { |c| c[:text].strip.empty? }
        end
      else
        data = OpenaiJson.chat_json(system: ROOT_SYS, user: root_prompt, api_key: api_key, temperature: 0.5)
        Array(data["questions"]).first(8).map { |q| { kind: "question", text: q.to_s } }.reject { |c| c[:text].strip.empty? }
      end
    when "answer"
      if mote?
        # 褒めフレーズ(answer)を展開 → 同じ趣旨の言い回しバリエーションを追加生成
        data = OpenaiJson.chat_json(system: MOTE_VARIATION_SYS, user: mote_variation_prompt, api_key: api_key, model: "gpt-4o", temperature: 0.9)
        Array(data["phrases"]).first(6).map { |p| { kind: "answer", text: p.to_s } }.reject { |c| c[:text].strip.empty? }
      else
        # 回答(answer)を展開 → その回答を受けて面接官/インタビュアーが続けて聞きそうな深掘り質問
        sys = youtube? ? YOUTUBE_ANSWER_SYS : ANSWER_SYS
        data = OpenaiJson.chat_json(system: sys, user: answer_prompt, api_key: api_key, model: ("gpt-4o" if youtube?), temperature: youtube? ? 0.7 : 0.5)
        Array(data["followups"]).first(4).map { |f| { kind: "followup", text: f.to_s } }.reject { |c| c[:text].strip.empty? }
      end
    else
      if mote?
        # カテゴリ(question)を展開 → そのカテゴリの褒めフレーズ(answer)を追加生成
        data = OpenaiJson.chat_json(system: MOTE_SYS, user: mote_prompt, api_key: api_key, model: "gpt-4o", temperature: 0.85)
        Array(data["phrases"]).first(8).map { |p| { kind: "answer", text: p.to_s } }.reject { |c| c[:text].strip.empty? }
      else
        sys = youtube? ? YOUTUBE_QA_SYS : QA_SYS
        temp = youtube? ? 0.7 : 0.4
        data = OpenaiJson.chat_json(system: sys, user: qa_prompt, api_key: api_key, model: ("gpt-4o" if youtube?), temperature: temp)
        out = []
        out << { kind: "answer", text: data["answer"].to_s } if data["answer"].to_s.strip.present?
        # キーワードノードは廃止（QとAだけにする方針）
        Array(data["followups"]).first(4).each { |f| out << { kind: "followup", text: f.to_s } unless f.to_s.strip.empty? }
        out
      end
    end
  end

  private

  def youtube? = @mindmap.youtube?
  def mote? = @mindmap.mote?

  # onclass リサーチ(高再生の傾向)を差し込むブロック。YouTube 以外や取得失敗時は空文字。
  def research_block
    return "" unless youtube?
    research = YoutubeResearchReader.cached_summary
    return "" if research.blank?
    "\n【YouTubeリサーチ(高再生の傾向・視聴者の言葉の参考。質問の切り口づくりに使う。事実は創作しない)】\n#{research}\n"
  end

  ROOT_SYS = <<~SYS.freeze
    あなたはIT業界の面接・商談同席経験が豊富な面接対策コーチです。与えられたスキルシートを読み込み、
    実際の面談で聞かれる可能性が高い順に、答える価値のある質問を予測します。
    次の JSON で返してください: { "questions": ["質問1", "質問2", ...] }  ※6〜8個。

    【質問者の視点を混ぜる】
    - 技術リーダー視点: 直近案件の技術選定・設計判断・実装の深掘り
    - 現場PM視点: 進め方・チーム開発・コミュニケーション・トラブル対応
    - 決裁者視点: 強み(自己PR)・キャリア観・カルチャーフィット・逆質問
    【質問の作り方】
    - スキルシートの**固有名詞(案件名・技術名)を質問文に入れて具体的に**する（例:「Railsの案件では〜」）。誰にでも聞ける一般論だけにしない。
    - 「定番で必ず聞かれる質問」と「答えに詰まりやすい鋭い質問」を両方入れる。
    - 直近の案件・得意技術ほど優先して深掘りする。
    - 事実(スキルシート)に無い経歴・技術を前提にした質問は作らない。
  SYS

  QA_SYS = <<~SYS.freeze
    あなたは技術者の面接対策コーチです。与えられた「質問」に対して、本人がそのまま言える回答案を作ります。
    次の JSON で返してください:
    { "answer": "結論を端的に。**多くて2行(最大80字程度)**まで。前置き・言い訳・冗長な説明は入れない。面接で口頭でサッと言える短さ",
      "keywords": ["暗唱用キーワード(回答の骨子3〜5個)", "..."],
      "followups": ["面接官が続けて聞きそうな深掘り質問", "..."] }
    【answer の作り方】
    - **質問に真正面から答える**（聞かれたことをズラさない）。結論→一言の根拠、の順。
    - 根拠はスキルシートの**実案件・実技術を1つだけ**添える。数字(期間・人数・件数)があれば使う。
    - 「〜だと思います」を連発しない。**自信のある言い切り**(です・ます調)で、実際に人が話す自然な話し言葉。教科書的・機械的にしない。
    - 事実(スキルシート)にもとづき、盛らない・創作しない。長い説明は answer に詰め込まず followups に回す。
    【followups の作り方】
    - この回答を聞いた面接官が「確認したくなる能力」（技術の深さ・判断の理由・再現性・チームでの動き）を突く質問にする。
  SYS

  YOUTUBE_ROOT_SYS = <<~SYS.freeze
    あなたはYouTubeインタビュー/解説動画の構成作家です。
    与えられた【動画タイトル/テーマ】に**厳密に沿って**、その動画で扱う想定質問を、視聴者が見たくなる自然な流れで組み立てます。
    最重要: **タイトルのテーマから外れた質問は作らない**。
    【構成】導入(視聴者の悩み・疑問に共感して引き込むフック) → 本編(具体的な中身。成功だけでなく失敗・つまずきも) → 締め(まとめ・視聴者への一言)。
    例: タイトルが「未経験からWebエンジニア転職までのロードマップ」なら、学習の順番・各ステップで何をやったか・つまずきと対処・ポートフォリオ・転職活動・かかった期間など、ロードマップを追える質問にする(汎用の人生インタビューにしない)。
    【質問の質】視聴者が検索しそうな悩みベースの言葉を使う。「実際どうだった?」「ぶっちゃけ〜?」のような本音を引き出す聞き方を織り交ぜる。数字(期間・金額・件数)を引き出す質問を1つ以上入れる。
    出演者のプロフィール/スキルシートがあれば内容に反映し、無い事実は作らない。
    次の JSON で返してください: { "questions": ["質問1", "質問2", ...] }  ※8〜12個。既出の質問とは重複させない。
  SYS

  YOUTUBE_QA_SYS = <<~SYS.freeze
    あなたはYouTubeのインタビュー動画の制作者であり、出演者本人になりきって質問に答えます。
    次の JSON で返してください:
    { "answer": "出演者本人がカメラに向かって自然に語る回答(一人称)",
      "followups": ["インタビュアーが続けて聞きそうな質問", "..."] }
    【口調・スタイル】
    - 出演者本人の**一人称**で語る(「私は」「〜なんです」「〜でした」など)。
    - **毎回名乗らない**。名前(「〜です」)や「こんにちは」の挨拶は『自己紹介』の質問のときだけ。それ以外の質問では名乗らず・挨拶せず、本題から自然に話し始める。
    - YouTubeの語り口で、自然で人間味があり、視聴者に語りかけるように。教科書的・箇条書き的にしない。
    - **端的に**。長くしすぎない。**2〜3文(おおよそ120字以内)**でテンポよく。エピソードを入れるなら1つだけ、短く。前置き・冗長な説明はしない。
    - 事実(プロフィール/スキルシート)にもとづき、**盛らない・創作しない**。収入などの数字は根拠が無ければ断定せず「〜くらい」「具体的な額より◯◯が変わった」等に逃がす。
  SYS

  ANSWER_SYS = <<~SYS.freeze
    あなたは技術者の面接対策コーチです。「質問」とそれに対する本人の「回答」を読み、面接官がその回答を受けて続けて聞きそうな深掘り質問を予測します。
    次の JSON で返してください: { "followups": ["深掘り質問", "..."] }  ※3〜4個。
    【作り方】
    - 回答に出てきた**技術・判断・経緯・数字を名指しで**突っ込む。一般論ではなく、この回答だからこそ聞かれる質問。
    - 面接官の意図で散らす: なぜその選択?(意思決定) / 他の案件でも再現できる?(再現性) / うまくいかなかった時は?(失敗対応) / 成果は数字で?(定量)
    - 少なくとも1つは、**答えに詰まりやすい鋭い質問**（圧迫ではなく、準備しておくと差がつくレベル）を入れる。
    - 口頭でそのまま聞ける短い文にする。既出の質問と重複させない。
  SYS

  YOUTUBE_ANSWER_SYS = <<~SYS.freeze
    あなたはYouTubeインタビュー動画のインタビュアーです。出演者の「回答」を受けて、視聴者が続きを聞きたくなる次の質問を考えます。
    次の JSON で返してください: { "followups": ["質問", "..."] }  ※3〜4個。
    【作り方】
    - 回答に出た話題を一歩深掘りする、テンポの良い短い質問。「それって具体的には?」「一番きつかったのは?」のような口語で。
    - 1つは**視聴者がコメント欄で聞きそうな素朴な疑問**（初心者目線）を混ぜる。
    - 数字や固有名詞を引き出す質問を優先する。既出の質問と重複させない。
  SYS

  MOTE_VARIATION_SYS = <<~SYS.freeze
    あなたはモテ会話のプロです。相手(女性)のセリフに対する「返し」の、別の言い回しのバリエーションを作ります。
    次の JSON で返してください: { "phrases": ["返し", "..."] }  ※5個程度。値は『自分の返し』だけ(相手のセリフは入れない)。
    型: 聞く→共感→さりげなく褒める/質問で会話を広げる。タメ口の自然な話し言葉。
    NG: 自分の自慢、質問攻め、重い長文、下品・不快。元の返しや既出と丸かぶりさせない。
  SYS

  MOTE_SYS = <<~SYS.freeze
    あなたはモテ会話のプロです。相手(女性)の【セリフ】に対する、自然でモテる『返し』を複数作ります。
    次の JSON で返してください: { "phrases": ["返し", "..."] }  ※5個程度。値は『自分の返し』だけ(相手のセリフは入れない)。
    【返しの型】聞く→共感→さりげなく褒める or 質問で会話を広げる。
    【スタイル】タメ口の自然な話し言葉。さりげなく(ホスト感を出さない)。外見だけでなく内面・気遣いも。
    【NG】自分の自慢、質問攻め、重い長文、下品・不快。既出と丸かぶりさせない。
  SYS

  # YouTube用プロフィール(あれば優先)。無ければスキルシートの自己PRを参考にする。
  def youtube_profile
    return nil unless @sheet
    @sheet.youtube_self_pr.presence || @sheet.self_pr.presence
  end

  def person_name = @mindmap.user&.display_name.to_s

  def sheet_summary
    return "（スキルシート情報なし）" unless @sheet
    lines = []
    lines << "得意技術: #{@sheet.skills}" if @sheet.skills.present?
    lines << "得意分野: #{@sheet.specialties}" if @sheet.specialties.present?
    lines << "自己PR: #{@sheet.self_pr.to_s.slice(0, 600)}" if @sheet.self_pr.present?
    @sheet.projects.order(:position).each do |p|
      lines << "■案件: #{p.title}（#{p.period_from}〜#{p.period_to}）使用技術: #{[ p.languages, p.tools ].compact.join(' ')}"
      lines << "  #{p.description.to_s.gsub(/\s+/, ' ').slice(0, 300)}"
    end
    lines.join("\n")
  end

  def path_to_root
    chain = []
    cur = @node
    while cur
      chain.unshift("#{cur.kind}: #{cur.text}") unless cur.kind == "root"
      cur = cur.parent
    end
    chain.join(" / ")
  end

  def root_prompt = "次のスキルシートから想定質問を予測してください:\n\n#{sheet_summary}"

  # YouTube 起点展開: 動画タイトル/テーマに沿った想定質問を作らせる
  def youtube_root_prompt(existing = [])
    dup = existing.present? ? "【すでにある質問(重複させない)】\n#{existing.map { |t| "・#{t}" }.join("\n")}\n\n" : ""
    <<~TXT
      【動画タイトル/テーマ】#{@mindmap.title}
      【出演者】#{person_name}
      【YouTube用プロフィール / 自己PR(参考)】
      #{youtube_profile.presence || "（プロフィール情報なし。タイトルのテーマ中心に組み立てる）"}

      【スキルシート】
      #{sheet_summary}
      #{research_block}
      #{dup}このタイトル/テーマに厳密に沿った、動画で聞く想定質問を作ってください。
    TXT
  end

  def qa_prompt
    header = +""
    if youtube?
      header << "【出演者(本人)】#{person_name}\n"
      header << "【動画タイトル/テーマ】#{@mindmap.title}\n" if @mindmap.title.present?
      header << "【YouTube用プロフィール / 自己PR(参考)】\n#{youtube_profile}\n\n" if youtube_profile.present?
      header << if @node.text.include?("自己紹介")
        "【この質問は自己紹介です。冒頭で一度だけ名乗ってください】\n"
      else
        "【自己紹介ではありません。名乗らず・挨拶せず(「こんにちは」「◯◯です」を付けず)、本題から話し始めてください】\n"
      end
    end
    <<~TXT
      #{header}【スキルシート】
      #{sheet_summary}

      【これまでの質問の流れ】#{path_to_root}
      【今回答える質問】#{@node.text}
    TXT
  end

  MOTE_CAT_SYS = <<~SYS.freeze
    あなたはモテ会話の「相手のセリフ出し」のプロです。会話で相手(女性)が言いがちな"一言"を新しく挙げます。
    次の JSON で返してください: { "categories": ["相手のセリフ", "..."] }  ※6個程度。**既出と重複させない**。
    例: 「最近疲れてて」「髪切ったんだ」「何食べる？」「映画好きなんだ」など、返しがしやすい自然なセリフ。
    前向きで健全な話題のみ。下品・不快・身体的特徴の不躾な指摘はしない。
  SYS

  # 既存の相手セリフを渡して、重複しない新しい相手のセリフを生成させる
  def mote_category_prompt(existing)
    <<~TXT
      【すでにある相手のセリフ(これらと重複させない)】
      #{existing.map { |t| "・#{t}" }.join("\n")}

      相手(女性)が言いがちな新しいセリフを考えてください。
    TXT
  end

  # answer ノード展開用: 親の質問と回答を渡し、深掘り質問を生成させる
  def answer_prompt
    question_text = @node.parent&.text.to_s
    existing_followups = @node.children.where(kind: %w[question followup]).order(:position).pluck(:text)
    header = +""
    if youtube?
      header << "【出演者(本人)】#{person_name}\n"
      header << "【動画タイトル/テーマ】#{@mindmap.title}\n" if @mindmap.title.present?
    end
    <<~TXT
      #{header}【スキルシート】
      #{sheet_summary}

      【これまでの質問の流れ】#{path_to_root}
      【質問】#{question_text}
      【本人の回答】#{@node.text}
      【すでにある深掘り質問(これらと重複させない)】
      #{existing_followups.map { |t| "・#{t}" }.join("\n")}

      この回答を受けて続けて聞きそうな深掘り質問を作ってください。
    TXT
  end

  # answer(返し) ノード展開用: 親=相手のセリフ。同じ相手セリフへの別の返しを生成
  def mote_variation_prompt
    aite = @node.parent&.text.to_s
    sibling_phrases = @node.parent ? @node.parent.children.where(kind: "answer").order(:position).pluck(:text) : []
    <<~TXT
      【相手のセリフ】#{aite}
      【ベースの返し】#{@node.text}
      【すでにある返し(これらと重複させない)】
      #{sibling_phrases.map { |t| "・#{t}" }.join("\n")}

      同じ相手のセリフに対して、言い回しの違う別の返しを作ってください。
    TXT
  end

  # question(相手のセリフ) ノード展開用: その相手セリフへのモテ返しを生成
  def mote_prompt
    existing = @node.children.where(kind: "answer").order(:position).pluck(:text)
    <<~TXT
      【相手のセリフ】#{@node.text}
      【すでにある返し(これらと重複させない)】
      #{existing.map { |t| "・#{t}" }.join("\n")}

      この相手のセリフに対する、自然でモテる返しを作ってください。
    TXT
  end
end
