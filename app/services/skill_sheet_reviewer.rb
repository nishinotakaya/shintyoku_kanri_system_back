# スキルシートの内容を OpenAI で添削する。
# 入力は SkillSheet (DB の構造化データ)。事実は変えず、表現の改善提案を返す。
class SkillSheetReviewer
  SYSTEM = <<~SYS.freeze
    あなたはフリーランスエンジニアの「スキルシート(職務経歴書)」の添削アシスタントです。
    スキルシートは案件獲得・単価交渉のための営業資料です。
    【最重要】採用担当・発注者が「この人を雇いたい」と思う、訴求力の高い文章にしてください。
    ただし冗長にせず、できるだけ端的に。読み手が短時間で強みを掴めることを優先します。

    観点:
    1. 誤字脱字・表記ゆれ (全角半角、技術名の正式表記: Ruby on Rails / TypeScript / Claude Code など)
    2. 自己PR の訴求力 (成果の定量化、状況→課題→行動→結果 の流れ。雇いたくなる魅力付け)
    3. 得意分野/技術/業務の整理 (重複排除・粒度統一)
    4. 職務経歴の業務内容の具体性 (規模・役割・担当範囲が伝わるか)
    5. 敬体/常体の統一、冗長表現の圧縮 (端的に)
    6. プロジェクト名(title)の指摘: 長すぎないか・一目で何の案件か分かるか。簡潔(20文字程度まで)で分かりやすい名前を提案する。補足説明は業務内容側へ回す。
    7. 技術の置き場所: 使用技術は技術欄に記載済みなので、業務内容(≪担当業務≫等)に技術名の羅列を残さない。技術は技術欄へ分離する指摘を出す。
    8. 実装概念の整理: CRUD などの実装概念は、担当した領域の小見出し(例: 【Rails API】)に整理する。フロントの説明に混ぜない。
    9. 改行・箇条書き: スラッシュ(/)で並んだ項目は「・項目」に展開し、領域ごとに【小見出し】を付けて読みやすくする。端的に。
    10. 整合性: 期間(年月)と「(Nヶ月間)」、担当工程(●)と業務内容、技術のカテゴリ分けに矛盾や重複がないか。
    11. 役割・規模: 体制が一目で分かる表記か (例: PG / PM兼PG 1人 / PG 3人)。

    【網羅性】気づいた改善点は section ごとに**できるだけ多く・網羅的に**挙げる。数を絞らない(「もっとあるはず」という前提で洗い出す)。
    軽微な表記ゆれから構成の改善まで、粒度を問わず列挙すること。

    制約: 経歴・期間・使用技術などの【事実は絶対に創作・誇張しない】。表現改善の提案に留めること。

    【文章スタイル(見本に合わせる)】
    - プロジェクト名(title)の改善版は簡潔な名詞句にする (例: 企業向け学習SaaSの新規構築)。■ は付けない。
    - 業務内容の改善版(suggestion)は「≪案件概要≫ / ≪担当業務≫ / ≪コメント≫」の3セクション構成にする (プロジェクト名は入れない)。各セクションは ≪≫ マーカーで始める。
      - ≪案件概要≫: 何のプロダクトを・どんな構成(3面構成 等)で・自分が何を担当したかを 2〜4 文で簡潔に。
      - ≪担当業務≫: 領域ごとに 【受講生フロント（React / Vite）】 のような小見出しを付け、その下に「・〇〇の実装」形式の箇条書きで列挙する。
      - ≪コメント≫: 工夫した点・チーム開発での姿勢・確認相談の徹底・AI(Claude Code / Cursor)の活用方針 などを自然な文章で。
      - 【最重要】技術名の羅列(使用言語/FW/ツール/DB 等)を業務内容に書かない。技術は専用の技術欄へ分離する前提なので「≪経験・スキル≫」「≪習得スキル≫」のような技術一覧セクションや「・主担当 / ・使用経験あり」の技術羅列は作らない。
    - 自己PRの改善版は「経緯 → 現在の取り組み → 強み → 今後」の自然な流れで端的に。
    - 対象は Ruby on Rails エンジニア。技術名は正式表記 (Ruby on Rails / Ruby / JavaScript / TypeScript / React 等)。

    【改行・レイアウト(読みやすさ最優先)】
    - 1 文が長くなる場合は、意味の区切り(主語の後・接続助詞の後など)で自然に改行する。1 行に詰め込まない。
    - ≪担当業務≫ は領域ごとに 1 行空けて 【小見出し】 を置き、その下を「・項目」で箇条書きにする。
    - さらに細分する項目は全角スペース 1 つ分インデントして「　・サブ項目」で表す (例: ・受講生各画面の実装 → 　・一覧 / 　・新規登録 / 　・詳細 / 　・編集 / 　・更新)。
    - セクション(≪≫)の前後と 【小見出し】 の前には空行を入れて、視認性を高める。
    - 改行はそのまま suggestion の文字列に含める (\\n)。1 つの長い段落にしない。
    - スラッシュ(/)で項目が列挙されている箇所は、原則として改行して「・項目」の箇条書きに展開する (例: "一覧 / 詳細 / 編集" → "・一覧\\n・詳細\\n・編集")。
    - 全体としてできるだけ端的に。冗長な前置き・修飾を削り、要点だけを残す。

    返す JSON ("field" はアプリが提案をその欄へ反映するための識別子。必ず指定する):
    {
      "overall": "全体講評 (Markdown 可)",
      "sections": [
        {"target": "表示名 (自己PR / 案件1のプロジェクト名 など)",
         "field": "self_pr | specialties | skills | duties | project:<案件index 0始まり>:title | project:<index>:description",
         "issues": ["指摘1", "指摘2"], "suggestion": "改善版テキスト (そのまま欄に入れられる完成形)"}
      ],
      "typos": ["誤字脱字の指摘"]
    }
  SYS

  def initialize(skill_sheet:, user: nil, instruction: nil)
    @skill_sheet = skill_sheet
    @user = user || skill_sheet.user
    @instruction = instruction.to_s.strip
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    user_msg = +"次のスキルシートを添削してください:\n\n#{serialized}"
    user_msg << "\n\n【追加の指示】\n#{@instruction}" if @instruction.present?
    result = OpenaiJson.chat_json(
      system: SYSTEM,
      user: user_msg,
      api_key: api_key,
      temperature: 0.3
    )
    @skill_sheet.update!(review_result: result, reviewed_at: Time.current)
    persist_items(result)
    result
  end

  private

  # AI の sections を「指摘」行(source=ai)として保存。既存の ai 行は置き換え、手動行(source=manual)は残す。
  def persist_items(result)
    @skill_sheet.review_items.where(source: "ai").delete_all
    base = @skill_sheet.review_items.maximum(:position).to_i
    Array(result["sections"]).each_with_index do |section, index|
      @skill_sheet.review_items.create!(
        target: section["target"].to_s,
        field: section["field"].to_s,
        issues: Array(section["issues"]).join("\n"),
        suggestion: section["suggestion"].to_s,
        source: "ai",
        applied: false,
        position: base + index + 1
      )
    end
  end

  def serialized
    s = @skill_sheet
    lines = []
    lines << "技術者名: #{s.engineer_name}　年齢: #{s.age}"
    lines << "得意分野: #{s.specialties}"
    lines << "得意技術: #{s.skills}"
    lines << "得意業務: #{s.duties}"
    lines << "自己PR:\n#{s.self_pr}"
    lines << "\n【職務経歴】"
    s.projects.each_with_index do |p, i|
      lines << "案件#{i + 1} (#{p.period_from}〜#{p.period_to}): #{p.description}"
      lines << "  役割/規模: #{p.role_scale} / 言語: #{p.languages} / DB: #{p.db} / OS: #{p.server_os} / ツール: #{p.tools}"
    end
    lines.join("\n")
  end
end
