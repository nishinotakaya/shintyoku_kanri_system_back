# 対象ユーザーの実際の開発実績 (Backlog タスク + その課題コメントのやりとり / 勤怠 work_reports) を
# 集約し、OpenAI でスキルシートの職務経歴・自己PR・得意技術を「下書き」生成する。
# 生成結果は SkillSheetImporter と同じ JSON 構造で返す (確認・編集してから保存する想定)。
#
# Backlog のコメント (関係者とのやりとり・課題と対応・コミット内容) には、タスク要約だけでは
# 拾えない「実際に何をしたか」が詰まっている。これを取り込むことで担当業務を具体化する。
class SkillSheetActivityComposer
  # Backlog コメント取り込みの上限 (トークン量の制御)
  MAX_COMMENT_CHARS_PER_TASK = 2_000
  MAX_COMMENT_CHARS_TOTAL = 14_000
  # コミットコメントに混入する定型行 (内容の本質ではないので除去する)
  COMMENT_NOISE_PATTERNS = [
    /Co-Authored-By:.*/i,
    /Generated with.*Claude.*/i,
    /\A🤖.*/,
    /\Ahttps?:\/\/\S+\z/ # 単独 URL 行
  ].freeze

  SYSTEM = <<~SYS.freeze
    あなたは SES のスキルシート(職務経歴書)を作成するプロのキャリアアドバイザーです。
    与えられる実績データ (Backlog のタスクと課題コメントのやりとり・勤怠の業務内容) を丁寧に読み、
    案件単位にまとめて次の JSON で返してください。実績に無い経歴・技術は創作しないこと。
    期間はデータの日付から推定してよい。

    【網羅性(重要)】
    - 完了・処理中の Backlog タスクは原則すべて案件(project)として反映する。実績を勝手に省略しない。
    - 異なるシステム・テーマ(例: 融資 / 火災保険 / 住宅家歴(引渡登録数の相違・キャンペーン工事) / 人事ナビ移行)は別々の案件にする。
      住宅家歴のデータ不整合調査・対応のような完了済みの業務を落とさないこと。
    - 同一システム内の細かい派生タスクのみ1案件にまとめてよい。未対応(未着手)のタスクは省いてよい。

    {
      "specialties": "得意分野 (実績から推定)",
      "skills": "得意技術 (登場した言語/FW/ツールをまとめる)",
      "duties": "得意業務",
      "self_pr": "自己PR (実績にもとづく、訴求力のある文章。創作禁止)",
      "projects": [
        {
          "period_from": "開始 (例: 2025年11月)",
          "period_to": "終了 (例: 2026年5月)",
          "title": "プロジェクト名 (簡潔に・20文字程度まで。■は付けない)",
          "description": "業務内容",
          "role_scale": "役割・規模",
          "languages": "使用言語",
          "db": "DB",
          "server_os": "サーバOS",
          "tools": "FW・MW・ツール等",
          "phases": {"要件定義": false, "基本設計": false, "詳細設計": false, "実装・単体": true, "結合テスト": false, "総合テスト": false, "保守・運用": false}
        }
      ]
    }

    【日本語(最重要)】
    - ネイティブの職務経歴書として自然で、簡潔・具体的な日本語にする。
    - 機械翻訳調・冗長な定型文(「〜に注力してきました」「多様な業務に取り組み」等のふわっとした表現)を避ける。
    - 主観的な美辞麗句より、何を・どう実装し・どんな課題を解決したかを事実ベースで書く。

    【文章スタイル(SES 標準フォーマットに厳密に合わせる)】
    - title(プロジェクト名) は簡潔に (20文字程度まで)。補足や規模はここに入れない。■ は付けない。
    - description(業務内容) は次の3ブロック構成にする (プロジェクト名は入れない):
      ≪案件概要≫
      <その案件で何を担当したかを1〜2文で>
      ≪担当業務≫
      【<カテゴリ名>】
      ・<具体的にやった作業。コメントのやりとりから読み取った実際の作業を反映する>
      ・<…>
      【<別カテゴリ>】
      ・<…>
      ≪コメント≫
      <成果・工夫・関係者との連携など、読み手が魅力を感じる一言。事実ベースで>
    - 担当業務はコメントのやりとり(課題報告・対応方針・コミット内容)を根拠に、抽象論でなく具体的な作業に落とす。
    - self_pr は3〜4文。実際に担当した領域(例: 権限管理画面の新規開発・データ不整合の原因調査と対応・インフラ移行 等、
      データから読み取れる具体テーマ)を必ず織り込み、何ができるエンジニアかが一読で伝わるようにする。
      次のような中身の薄い定型文は禁止: 「これまでの経験を通じて〜に従事してきました」「〜に注力しており」
      「多様な業務に取り組み」「今後も新しい技術を取り入れ〜努めていきます」。
      抽象的な姿勢表明ではなく、担当した具体的な仕事と、そこで発揮した強み(課題解決・関係者連携・保守性改善など)を事実で示す。
  SYS

  def initialize(user:)
    @user = user
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    data = OpenaiJson.chat_json(
      system: SYSTEM,
      user: "次の開発実績からスキルシートの下書きを作ってください:\n\n#{activity_text}",
      api_key: api_key,
      temperature: 0.4
    )
    data = data.to_h
    data["projects"] = Array(data["projects"]).map(&:to_h)
    data
  end

  private

  def activity_text
    sections = []
    sections << "【前提】対象は #{@user.dev_language.presence || 'Ruby on Rails'} エンジニア。"
    sections << backlog_section
    sections << work_report_section
    sections.compact.join("\n\n").presence ||
      raise("開発実績データ (Backlog タスク / 勤怠) が見つかりませんでした。")
  end

  # Backlog タスクを、各課題のコメントのやりとり付きで列挙する。
  def backlog_section
    tasks = @user.backlog_tasks.order(:start_date)
    return nil if tasks.empty?

    remaining_comment_budget = MAX_COMMENT_CHARS_TOTAL
    lines = [ "【Backlog タスク (#{tasks.size}件)】" ]
    tasks.each do |task|
      period = [ task.start_date, task.end_date ].compact.map(&:to_s).join("〜")
      memo = task.memo.to_s.gsub(/\s+/, " ").slice(0, 200)
      note = task.deploy_note.to_s.slice(0, 120)
      lines << "■ #{task.issue_key} #{task.summary} [#{task.status_name}] #{period} #{note} #{memo}".squeeze(" ").strip

      next if remaining_comment_budget <= 0
      digest = comment_digest_for(task, limit: [ MAX_COMMENT_CHARS_PER_TASK, remaining_comment_budget ].min)
      next if digest.blank?
      remaining_comment_budget -= digest.length
      lines << "  〔やりとり〕"
      digest.each_line { |line| lines << "  #{line.chomp}" }
    end
    lines.join("\n")
  end

  # 1課題ぶんのコメント本文を、ノイズ除去・整形して limit 文字に丸めて返す。
  def comment_digest_for(task, limit:)
    return nil if task.issue_key.blank? || backlog_client.nil?

    comments = fetch_comments(task.issue_key)
    bodies = comments.filter_map { |comment| clean_comment_body(comment["content"]) }
    return nil if bodies.empty?

    bodies.join("\n").slice(0, limit)
  end

  def clean_comment_body(content)
    text = content.to_s
    COMMENT_NOISE_PATTERNS.each { |pattern| text = text.gsub(pattern, "") }
    text = text.gsub(/\n{3,}/, "\n\n").strip
    text.presence
  end

  def fetch_comments(issue_key)
    backlog_client.fetch_comments(issue_key)
  rescue => e
    Rails.logger.warn("[SkillSheetActivityComposer] コメント取得失敗 #{issue_key}: #{e.message}")
    []
  end

  # @user の Backlog 設定からクライアントを生成 (API キー未設定なら nil = コメント取り込みをスキップ)。
  def backlog_client
    return @backlog_client if defined?(@backlog_client)
    setting = @user.backlog_setting
    @backlog_client = (setting && setting.api_key.present?) ? BacklogClient.new(setting) : nil
  rescue => e
    Rails.logger.warn("[SkillSheetActivityComposer] Backlog クライアント生成失敗: #{e.message}")
    @backlog_client = nil
  end

  def work_report_section
    reports = @user.work_reports.where.not(content: [ nil, "" ]).order(:work_date)
    return nil if reports.empty?
    by_cat = reports.group_by(&:category)
    lines = [ "【勤怠 業務内容】" ]
    by_cat.each do |cat, rs|
      contents = rs.map { |r| "#{r.work_date}: #{r.content}" }.last(60)
      lines << "■カテゴリ: #{cat || '未分類'}"
      lines.concat(contents.map { |c| "  - #{c}" })
    end
    lines.join("\n")
  end
end
