# スキルシートの各案件のフリーテキスト(使用言語/DB/サーバOS/ツール)を
# AI で技術トークンに正規化し、案件期間から「経験月数・最終使用・バージョン」を
# 横断集計して skill_sheet_techs に保存する。
#
# バージョンはメジャーのみ・任意 (例: Rails 7.1.2 → "7", React 19 → "19")。
# 同じ技術が複数案件・複数バージョンで出てきた場合:
#   - months_used = 全案件の期間合計
#   - version / last_used_on = 最も新しく使った案件のもの
class SkillSheetTechAnalyzer
  NORMALIZE_INSTRUCTION = <<~SYS.freeze
    あなたはエンジニアのスキルシートから「技術スタック」を抽出・正規化するアシスタントです。
    案件ごとの使用言語/DB/サーバOS/FW・MW・ツールのフリーテキストを読み取り、
    技術を 1 つずつに分解して正規化し、次の JSON だけを返してください。

    {
      "projects": [
        {
          "index": 0,
          "techs": [
            { "category": "language", "name": "Ruby on Rails", "version": "7" }
          ]
        }
      ]
    }

    ルール:
    - category は必ず次のいずれか: "language"(言語) / "framework"(FW・MW) / "db" / "server_os" / "tool"(その他ツール)
      - Rails/React/Vue/Spring 等のフレームワーク・ミドルウェアは "framework"
      - Ruby/JavaScript/TypeScript/Java/Python/PHP 等の言語は "language"
      - MySQL/PostgreSQL/Oracle/SQLite 等は "db"
      - Linux/CentOS/Windows Server/Amazon Linux 等は "server_os"
      - Git/Docker/AWS/Figma/Jira 等は "tool"
    - name は正式表記に統一する (例: "rails"→"Ruby on Rails", "TS"→"TypeScript", "postgres"→"PostgreSQL")
    - version は「メジャー番号のみ」。元テキストにバージョンが書かれている時だけ入れる
      (例: "Rails 7.1.2"→"7", "React 19"→"19", "Ruby 3.2"→"3")。書かれていなければ "" (空文字)。
    - 区切り(・, /, 、, 改行, カンマ等)で複数技術が並ぶ場合は分解する。
    - 技術名でないもの(担当範囲の説明文など)は除外する。
    - index は入力の案件番号をそのまま返すこと。事実を創作しないこと。
  SYS

  def initialize(skill_sheet:, user: nil)
    @sheet = skill_sheet
    @user = user
  end

  def call
    projects = @sheet.projects.to_a
    return persist({}) if projects.empty?

    normalized = normalize(projects)
    aggregated = aggregate(projects, normalized)
    persist(aggregated)
  end

  private

  # AI に投げて案件ごとの技術トークン配列を得る。{ project_index => [tech, ...] }
  def normalize(projects)
    payload = projects.each_with_index.map do |project, index|
      {
        index: index,
        period_from: project.period_from,
        period_to: project.period_to,
        languages: project.languages,
        db: project.db,
        server_os: project.server_os,
        tools: project.tools
      }
    end

    api_key = OpenaiClient.api_key_for(@user)
    data = OpenaiJson.chat_json(
      system: NORMALIZE_INSTRUCTION,
      user: "次の案件配列から技術スタックを抽出してください:\n\n#{JSON.pretty_generate(payload)}",
      api_key: api_key
    )

    Array(data["projects"]).each_with_object({}) do |entry, acc|
      acc[entry["index"].to_i] = Array(entry["techs"])
    end
  end

  # 案件期間 × 技術トークンを [category, name] 単位に畳み込む。
  def aggregate(projects, normalized)
    aggregated = {}
    projects.each_with_index do |project, index|
      span = month_span(project.period_from, project.period_to)
      to_rank = year_month_rank(project.period_to) || current_rank

      Array(normalized[index]).each do |tech|
        category = tech["category"].to_s.strip
        name = tech["name"].to_s.strip
        next if name.empty? || !SkillSheetTech::CATEGORIES.include?(category)

        key = [ category, name ]
        record = aggregated[key] ||= { category: category, name: name, months_used: 0, last_used_rank: -1, version: nil, last_used_on: nil }
        record[:months_used] += span
        # 最も新しく使った案件のバージョン・最終使用を採用
        if to_rank > record[:last_used_rank]
          record[:last_used_rank] = to_rank
          record[:version] = normalize_version(tech["version"])
          record[:last_used_on] = project.period_to.presence || "現在"
        end
      end
    end
    aggregated
  end

  def persist(aggregated)
    rows = aggregated.values
    SkillSheetTech.transaction do
      @sheet.techs.delete_all
      rows.each do |row|
        @sheet.techs.create!(
          category: row[:category],
          name: row[:name],
          version: row[:version],
          months_used: row[:months_used],
          last_used_on: row[:last_used_on],
          last_used_rank: row[:last_used_rank].negative? ? 0 : row[:last_used_rank]
        )
      end
    end
    @sheet.techs.reload
  end

  def normalize_version(value)
    version = value.to_s.strip
    return nil if version.empty?
    # 念のためメジャー番号だけに丸める (例: "7.1.2" → "7")
    version[/\A\d+/] || version
  end

  # period 文字列を year*12+month に正規化。"現在"/"present"/空 は現在月。
  def year_month_rank(value)
    text = value.to_s.strip
    return current_rank if text.empty? || text.match?(/現在|present|即日|now/i)
    matched = text.match(/(\d{4})\s*[年\/.\-]\s*(\d{1,2})/)
    return nil unless matched
    matched[1].to_i * 12 + matched[2].to_i
  end

  # from 〜 to の月数 (両端含む)。最低 1。
  def month_span(period_from, period_to)
    from_rank = year_month_rank(period_from)
    to_rank = year_month_rank(period_to) || current_rank
    return 1 if from_rank.nil?
    [ to_rank - from_rank + 1, 1 ].max
  end

  def current_rank
    @current_rank ||= begin
      today = Time.zone&.today || Date.today
      today.year * 12 + today.month
    end
  end
end
