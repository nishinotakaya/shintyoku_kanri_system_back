# スキルシートの技術欄(使用言語/DB/サーバOS/FW・MW・ツール)のセレクト候補を供給する。
# マスタ(よく使う技術の定型表記) + その管理スコープで既に登録された skill_sheet_techs の名称を合成する。
module SkillSheetTechCatalog
  # フォームのフィールドキー → 候補リスト
  MASTER = {
    "languages"  => %w[Ruby JavaScript TypeScript Java Python PHP Go C# Kotlin Swift Dart Scala HTML CSS SQL Shell].freeze,
    "db"         => [ "MySQL", "PostgreSQL", "Oracle", "SQLite3", "SQL Server", "MongoDB", "Redis", "DynamoDB", "MariaDB" ].freeze,
    "server_os"  => [ "Linux", "CentOS", "Amazon Linux", "Ubuntu", "Red Hat", "Windows Server", "Heroku", "AWS", "GCP", "Azure", "Vercel", "Fly.io" ].freeze,
    "tools"      => [
      "Ruby on Rails", "React", "Vue.js", "Next.js", "Nuxt.js", "Angular", "Spring", "Laravel", "Django", "Flask",
      "Express", "jQuery", "Bootstrap", "Tailwind CSS", "Sass", "Vite", "webpack", "Docker", "Kubernetes",
      "Git", "GitHub", "GitLab", "Backlog", "Jira", "Redmine", "Trello", "RSpec", "Jest", "Sidekiq",
      "VSCode", "Cursor", "Claude Code", "Figma", "Slack", "AWS", "Firebase"
    ].freeze
  }.freeze

  # skill_sheet_techs.category → フォームのフィールドキー
  CATEGORY_TO_FIELD = {
    "language"   => "languages",
    "framework"  => "tools",
    "db"         => "db",
    "server_os"  => "server_os",
    "tool"       => "tools"
  }.freeze

  FIELDS = MASTER.keys.freeze

  module_function

  # extra_by_field: { "languages" => ["Ruby on Rails", ...], ... } を MASTER に合成（重複排除・マスタ優先順）
  def candidates(extra_by_field = {})
    MASTER.each_with_object({}) do |(field, master_list), acc|
      extra = Array(extra_by_field[field]).map(&:to_s).reject(&:blank?)
      acc[field] = (master_list + extra).uniq
    end
  end

  # SkillSheetTech のレコード群を field 別の名称配列に振り分ける。
  # techs は [category, name] または [category, name, version] の配列。
  # version があれば「名称」と「名称 バージョン」の両方を候補に入れる（再集計stackをそのまま選べるように）。
  def extra_from_techs(techs)
    extra = Hash.new { |hash, key| hash[key] = [] }
    techs.each do |category, name, version|
      field = CATEGORY_TO_FIELD[category.to_s]
      next unless field && name.present?
      extra[field] << name.to_s
      extra[field] << "#{name} #{version}" if version.present?
    end
    extra.transform_values(&:uniq)
  end
end
