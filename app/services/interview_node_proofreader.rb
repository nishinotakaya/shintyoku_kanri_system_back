# マインドマップの1ノードのテキストを AI で添削する。
# 目的: 受け取った回答メモを「実際に人が話しているような自然な話し言葉」にまとめ直す。
# - 誤字脱字・不自然な日本語・冗長・重複を直す
# - 結論ファーストで簡潔に（口で言える地の文にする）
# - 事実(スキルシート・質問)に無いことは足さない・盛らない。元の意味は変えない
# 返り値: 添削後テキスト(String)。呼び出し側で「保存せず編集欄に差し込む」非破壊運用。
class InterviewNodeProofreader
  def initialize(mindmap:, node:, user:)
    @mindmap = mindmap
    @node = node
    @user = user # OpenAI APIキー解決用(操作者)
    @sheet = mindmap.skill_sheet || mindmap.user.skill_sheet
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    data = OpenaiJson.chat_json(system: system_prompt, user: prompt, api_key: api_key, model: "gpt-4o", temperature: 0.4)
    data["corrected"].to_s.strip
  end

  private

  def youtube? = @mindmap.youtube?
  def mote? = @mindmap.mote?

  def system_prompt
    return YOUTUBE_SYS if youtube?
    return MOTE_SYS if mote?
    INTERVIEW_SYS
  end

  INTERVIEW_SYS = <<~SYS.freeze
    あなたは面接対策コーチ兼・日本語の校正者です。受け取った「面接の回答メモ」を、本人が面接でそのまま口に出せる文章に添削します。
    次の JSON で返してください: { "corrected": "添削後の回答(全文)" }
    【添削方針】
    - **実際に人が面接で話しているような、自然な話し言葉(です・ます調)**にまとめる。翻訳調・教科書的・箇条書き的・機械的にしない。
    - 結論ファースト。冗長な前置き・言い訳・重複を削り、**多くて2〜3文(目安120字以内)**に簡潔にまとめる。
    - 「〜だと思います」「〜な感じです」の連発など**弱い言い回しは自信のある言い切りに直す**（謙虚さは残しつつ、頼りなく聞こえないように）。
    - 誤字脱字・不自然な言い回し・助詞の誤り・主語と述語のねじれを直す。話し言葉でも敬語は正しく。
    - 箇条書き・記号・見出しは使わず、声に出して言える地の文にする。
    - 事実(スキルシート・質問)に無い経歴・技術・数字は足さない・盛らない。元の意味を変えない。
  SYS

  YOUTUBE_SYS = <<~SYS.freeze
    あなたはYouTube台本の校正者です。出演者本人が一人称でカメラに語る言葉に添削します。
    次の JSON で返してください: { "corrected": "添削後のセリフ(全文)" }
    【添削方針】
    - 出演者本人の**一人称**で、視聴者に語りかける**自然な話し言葉**にまとめる。人間味を残し、教科書的・棒読み調にしない。
    - **端的に**。2〜3文(目安120字以内)。前置き・冗長な説明・重複は削る。
    - 自己紹介の回答でなければ、名乗らない・「こんにちは」等の挨拶を付けない。
    - 誤字脱字・不自然な言い回しを直す。事実(プロフィール/スキルシート)に無いことは盛らない・創作しない。
  SYS

  MOTE_SYS = <<~SYS.freeze
    あなたはモテる会話(さりげない褒め言葉)の校正者です。受け取ったフレーズを、自然でさりげない一言に整えます。
    次の JSON で返してください: { "corrected": "添削後のフレーズ" }
    【添削方針】
    - **短い一言・タメ口の話し言葉**にまとめる。あざとすぎず、さりげなく。
    - 不自然な言い回し・誤字を直す。下品・不快・身体的特徴の不躾な指摘にしない。
    - 元フレーズの趣旨は変えない。
  SYS

  def prompt
    parts = []
    parts << "【スキルシート(参考・事実の範囲)】\n#{sheet_summary}" if @sheet
    parent = @node.parent
    if parent
      if mote?
        parts << "【お題・カテゴリ】#{parent.text}"
      elsif @node.kind == "answer"
        parts << "【この回答が答えている質問】#{parent.text}"
      end
    end
    flow = path_to_root
    parts << "【これまでの流れ】#{flow}" if flow.present?
    parts << "【添削対象のテキスト】\n#{@node.text}"
    parts.join("\n\n")
  end

  def sheet_summary
    return "（スキルシート情報なし）" unless @sheet
    lines = []
    lines << "得意技術: #{@sheet.skills}" if @sheet.skills.present?
    lines << "得意分野: #{@sheet.specialties}" if @sheet.specialties.present?
    lines << "自己PR: #{@sheet.self_pr.to_s.slice(0, 400)}" if @sheet.self_pr.present?
    @sheet.projects.order(:position).each do |project|
      lines << "■案件: #{project.title}（使用技術: #{[ project.languages, project.tools ].compact.join(' ')}）"
    end
    lines.join("\n")
  end

  def path_to_root
    chain = []
    current = @node.parent
    while current
      chain.unshift("#{current.kind}: #{current.text}") unless current.kind == "root"
      current = current.parent
    end
    chain.join(" / ")
  end
end
