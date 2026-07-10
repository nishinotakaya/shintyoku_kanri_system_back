# 対応ログ(Backlog活動 + Notionタスク)から、スキルシートの職務経歴(案件)を1件 AI 生成する。
# SkillSheetActivityComposer(全体の下書き生成)と違い、こちらは「今までの対応ログをまとめて1案件にする」
# 用途。期間は AI に作らせず、対応ログの実日付(min/max)から機械的に算出する(創作させない)。
class BacklogToSkillSheetProjectBuilder
  # プロンプトに渡す素材の上限(トークン量の制御)
  MAX_ISSUES = 80
  MAX_NOTION_TASKS = 40

  INSTRUCTION = <<~SYS.freeze
    あなたはエンジニアの対応ログ(Backlogの課題対応履歴・Notionタスク)から、
    スキルシートの職務経歴(案件)を1件だけ作成するアシスタントです。
    次の JSON だけを返してください。

    {
      "title": "案件名(例: 進捗管理・業務システムの開発運用保守)",
      "description": "何をしたか。・箇条書き改行区切りで具体的に(課題の実内容ベース)",
      "role_scale": "役割・規模(例: 開発担当 / チーム2名)",
      "languages": "改行区切りタグ",
      "db": "改行区切りタグ",
      "server_os": "改行区切りタグ",
      "tools": "改行区切りタグ",
      "phases": "改行区切り(例: 詳細設計\\n実装\\nテスト\\n運用保守)"
    }

    ■ 最重要ルール(事実ベース):
    - 課題タイトル・内容から読み取れる技術/作業のみ書き、創作しない。
    - 読み取れない欄は空文字にする。
    - description は「・」始まりの箇条書きで5〜10行、実際の課題内容(機能名・改修内容)を具体的に書く。

    ■ languages/db/server_os/tools のカテゴリ分けルール:
    - languages: Ruby/JavaScript/TypeScript/Java/Python/PHP 等の言語
    - db: MySQL/PostgreSQL/Oracle/SQLite 等
    - server_os: Linux/CentOS/Amazon Linux/Heroku/AWS/GCP 等
    - tools: Rails/React/Vue/Next.js 等のフレームワークと、Git/GitHub/Docker/Jira 等のその他ツールの両方
    - name は正式表記に統一する("rails"→"Ruby on Rails", "TS"→"TypeScript", "postgres"→"PostgreSQL")
    - 区切り(・ / 、, 改行, カンマ, スラッシュ)で並ぶものは1つずつに分解して改行区切りで返す。
  SYS

  # user: 操作者(OpenAIキー解決用) / skill_sheet: 対象のスキルシート(対象者は skill_sheet.user)
  def initialize(skill_sheet:, user:)
    @sheet = skill_sheet
    @target_user = skill_sheet.user
    @operator_user = user
  end

  def call
    activities = BacklogActivity.where(user_id: @target_user.id).to_a
    raise "対応ログがありません。先に対応ログの同期を実行してください。" if activities.empty?

    period_from, period_to = build_period(activities)

    data = OpenaiJson.chat_json(
      system: INSTRUCTION,
      user: build_prompt(activities),
      api_key: OpenaiClient.api_key_for(@operator_user),
      model: "gpt-4o",
      temperature: 0.5
    )

    position = @sheet.projects.maximum(:position).to_i + 1
    project = @sheet.projects.create!(
      position: position,
      period_from: period_from,
      period_to: period_to,
      title: data["title"].to_s.strip,
      description: data["description"].to_s.strip,
      role_scale: data["role_scale"].to_s.strip,
      languages: data["languages"].to_s.strip,
      db: data["db"].to_s.strip,
      server_os: data["server_os"].to_s.strip,
      tools: data["tools"].to_s.strip,
      phases: build_phases(data["phases"]),
      source: "backlog"
    )
    project.as_payload
  end

  private

  # 対応ログの実日付から期間文字列("2026年4月")を算出する。当月まで対応していれば終了は「現在」。
  def build_period(activities)
    dates = activities.filter_map(&:occurred_on)
    min_date = dates.min
    max_date = dates.max
    period_from = format_period(min_date)
    period_to = max_date.beginning_of_month == Date.current.beginning_of_month ? "現在" : format_period(max_date)
    [ period_from, period_to ]
  end

  def format_period(date)
    date.strftime("%Y年%-m月")
  end

  # AI が返した「改行区切りの担当工程」を、フォームの phases チェック(PHASE_KEYS)の bool マップへ変換する。
  # (SkillSheetProject#phases は Hash 型で保存されるため、そのまま文字列を入れることはできない)
  PHASE_KEYWORDS = {
    "要件定義"   => %w[要件定義 要件],
    "基本設計"   => %w[基本設計],
    "詳細設計"   => %w[詳細設計],
    "実装・単体" => %w[実装 単体],
    "結合テスト" => %w[結合テスト 結合],
    "総合テスト" => %w[総合テスト 総合 システムテスト テスト],
    "保守・運用" => %w[保守 運用]
  }.freeze

  def build_phases(raw_phases)
    lines = raw_phases.to_s.split(/[\n、,・]/).map(&:strip).reject(&:empty?)
    SkillSheetProject::PHASE_KEYS.index_with do |phase_key|
      keywords = PHASE_KEYWORDS[phase_key] || [ phase_key ]
      lines.any? { |line| keywords.any? { |keyword| line.include?(keyword) } }
    end
  end

  def build_prompt(activities)
    parts = []
    parts << "【対象者】#{@target_user.display_name}"
    parts << issues_section(activities)
    notion = notion_tasks_section
    parts << notion if notion.present?
    techs = techs_section
    parts << techs if techs.present?
    parts << "\n上記の対応ログをもとに、1つの案件としてまとめてください。"
    parts.join("\n\n")
  end

  # 課題(issue_key)単位に活動を集約し、一覧テキストを作る。
  def issues_section(activities)
    grouped = activities.group_by(&:issue_key)
    issues = grouped.map do |issue_key, rows|
      summary = rows.sort_by { |r| r.occurred_on || Date.new(1) }.reverse.filter_map(&:summary).find(&:present?)
      comment_count = rows.count { |r| r.activity_type == "comment" }
      status_count  = rows.count { |r| r.activity_type == "status" }
      commit_count  = rows.count { |r| r.activity_type == "commit" }
      dates = rows.filter_map(&:occurred_on)
      period = "#{dates.min&.strftime('%Y-%m')}〜#{dates.max&.strftime('%Y-%m')}"
      {
        issue_key: issue_key,
        line: "#{issue_key}: #{summary}（コメント#{comment_count}件/状態変更#{status_count}件/コミット#{commit_count}件, 期間 #{period}）",
        first_date: dates.min
      }
    end
    issues = issues.sort_by { |i| i[:first_date] || Date.new(1) }.first(MAX_ISSUES)
    "【対応した課題(#{issues.size}件)】\n" + issues.map { |i| i[:line] }.join("\n")
  end

  # 対象者の苗字(display_name の最初の空白区切り)を含む NotionTask のみ使う(グローバルなので絞り込み必須)。
  def notion_tasks_section
    surname = @target_user.display_name.to_s.split(/\s+/).first
    return nil if surname.blank?

    tasks = NotionTask.where("assignee_name LIKE ?", "%#{surname}%").order(:start_date).first(MAX_NOTION_TASKS)
    return nil if tasks.empty?

    lines = tasks.map do |task|
      period = "#{task.start_date&.strftime('%Y-%m-%d')}〜#{task.end_date&.strftime('%Y-%m-%d')}"
      "#{task.title}（#{task.status}, #{period}）"
    end
    "【Notionタスク(#{tasks.size}件)】\n" + lines.join("\n")
  end

  # 本人のスキルシートに既に登録済みの技術タグ(あれば参考情報として渡す)。
  def techs_section
    techs = @sheet.techs.to_a
    return nil if techs.empty?

    labels = techs.map { |tech| tech.version.present? ? "#{tech.name} #{tech.version}" : tech.name }
    "【本人の技術タグ一覧(参考)】\n#{labels.join('、')}"
  end
end
