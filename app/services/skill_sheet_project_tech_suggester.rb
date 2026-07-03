# 各案件のフリーテキスト(使用言語/DB/サーバOS/FW・MW・ツール + 業務内容)を AI で正規化し、
#   1) フォームの 4 技術欄にそのまま入れられる「改行区切りタグ文字列」
#   2) ≪経験・スキル≫ 内の技術名の羅列を取り除いた業務内容(description)
# を案件ごとに返す。集計(skill_sheet_techs)は作らない＝あくまで入力補助(タグ整形)。
#
# 例: ≪経験・スキル≫の "React / JavaScript / Ruby on Rails ..." を tools/languages へ振り分け、
#     その羅列行は description から削除（"セルフレビュー文化..." 等の非技術記述は残す）。
class SkillSheetProjectTechSuggester
  CATEGORY_TO_FIELD = SkillSheetTechCatalog::CATEGORY_TO_FIELD

  INSTRUCTION = <<~SYS.freeze
    あなたはエンジニアのスキルシートの各案件から「技術スタック」を抽出・正規化し、
    さらに業務内容(description)から技術名の羅列を取り除くアシスタントです。
    次の JSON だけを返してください。

    {
      "projects": [
        {
          "index": 0,
          "techs": [ { "category": "language", "name": "Ruby on Rails", "version": "7" } ],
          "cleaned_description": "技術名の羅列を取り除いた業務内容"
        }
      ]
    }

    ■ techs のルール:
    - category は必ず: "language"(言語) / "framework"(FW・MW) / "db" / "server_os" / "tool"(その他ツール)
      - Rails/React/Vue/Next.js/Spring/Tailwind CSS/MUI/jQuery 等のフレームワーク・MW・ライブラリは "framework"
      - Ruby/JavaScript/TypeScript/Java/Python/PHP 等の言語は "language"
      - MySQL/PostgreSQL/Oracle/SQLite 等は "db"
      - Linux/CentOS/Amazon Linux/Heroku/AWS/GCP 等は "server_os"
      - Git/GitHub/Docker/Vite/RSpec/Figma/Jira/Claude Code/Cursor 等は "tool"
    - name は正式表記に統一 ("rails"→"Ruby on Rails", "TS"→"TypeScript", "postgres"→"PostgreSQL")
    - version は「メジャー番号のみ」。元テキストに書かれている時だけ ("Rails 7.0.8.1"→"7", "React 18.2"→"18")。無ければ ""。
    - 区切り(・ / 、, 改行, カンマ, スラッシュ)で並ぶものは 1 つずつに分解する。
    - 「AI駆動開発（Claude Code / Cursor）」のような表現からは Claude Code(tool)・Cursor(tool) を抽出する。
    - 「チーム開発」「セルフレビュー文化」等の技術名でない語は techs に含めない。
    - 入力の使用言語/DB/サーバOS/FW・MW・ツール欄 と 業務内容(description) の両方から拾う。

    ■ cleaned_description のルール:
    - 入力 description のうち ≪経験・スキル≫ セクション内にある「技術名を ・ / 、, スラッシュ 等で並べた羅列行」だけを削除する。
      (例: "React / JavaScript / TypeScript / Ruby on Rails ..." の行や "Vite / Zustand / ..." の行)
    - その結果 "・主担当" "・使用経験あり" などの見出しだけが残って中身が空になる場合は、その見出し行も削除する。
    - 技術名でない記述(例: "セルフレビュー文化（CRITICAL/HIGH/MEDIUM/LOW 4段階分類）")や、
      ≪案件概要≫≪担当業務≫≪コメント≫ など他セクションの本文は一字一句そのまま残す。
    - マーカー(≪...≫)と改行・段落はそのまま保持する。section ごと消してはいけない。
    - 事実を創作しない。技術以外の文章を要約・改変しない。

    index は入力の案件番号をそのまま返すこと。
  SYS

  def initialize(skill_sheet:, user: nil)
    @sheet = skill_sheet
    @user  = user
  end

  # => [{ "index"=>0, "languages"=>"...", "db"=>"...", "server_os"=>"...", "tools"=>"...", "description"=>"..." }, ...]
  def call
    projects = @sheet.projects.order(:position).to_a
    return [] if projects.empty?

    payload = projects.each_with_index.map do |project, index|
      {
        index: index,
        languages: project.languages,
        db: project.db,
        server_os: project.server_os,
        tools: project.tools,
        description: project.description
      }
    end

    data = OpenaiJson.chat_json(
      system: INSTRUCTION,
      user: "次の案件配列を処理してください:\n\n#{JSON.pretty_generate(payload)}",
      api_key: OpenaiClient.api_key_for(@user)
    )
    by_index = Array(data["projects"]).index_by { |entry| entry["index"].to_i }

    projects.each_with_index.map do |project, index|
      entry = by_index[index]
      fields = group_techs(Array(entry&.dig("techs")))
      cleaned = entry&.dig("cleaned_description")
      {
        "index"       => index,
        "languages"   => fields["languages"].join("\n"),
        "db"          => fields["db"].join("\n"),
        "server_os"   => fields["server_os"].join("\n"),
        "tools"       => fields["tools"].join("\n"),
        "description" => cleaned.is_a?(String) && cleaned.strip.present? ? cleaned : project.description.to_s
      }
    end
  end

  private

  def group_techs(techs)
    fields = Hash.new { |hash, key| hash[key] = [] }
    techs.each do |tech|
      field = CATEGORY_TO_FIELD[tech["category"].to_s]
      next unless field
      name = tech["name"].to_s.strip
      next if name.empty?
      version = tech["version"].to_s.strip
      label = version.empty? ? name : "#{name} #{version}"
      fields[field] << label unless fields[field].include?(label)
    end
    %w[languages db server_os tools].each { |f| fields[f] }
    fields
  end
end
