require "net/http"
require "csv"

# スプレッドシートの URL を受け取り、中身を読み取って構造化する。
# 1) 公開シート: gviz CSV エクスポート (認証不要)
# 2) 失敗したら: OAuth (Google Sheets API) で読み取り
# 読み取った CSV を OpenAI で JSON 構造化して返す (raw_content も返す)。
class SkillSheetImporter
  # CSV のセルをどの項目に対応づけるかだけを判定する「位置合わせ専用」プロンプト。
  # 内容の書き換え・要約・整形・正規化は一切しない（シートの文言をそのまま取り込む）。
  STRUCTURE_INSTRUCTION = <<~SYS.freeze
    あなたはスキルシート(職務経歴書)の CSV を、項目ごとに振り分けるだけのアシスタントです。
    各セルの値を「どの項目か」だけ判定し、**文言は一字一句そのまま**で次の JSON に入れてください。

    {
      "engineer_name": "技術者名",
      "age": "年齢",
      "gender": "性別",
      "address": "住所/所在",
      "start_date": "稼動開始",
      "nearest_station": "最寄駅",
      "specialties": "得意分野",
      "skills": "得意技術",
      "duties": "得意業務",
      "self_pr": "自己PR",
      "projects": [
        {
          "period_from": "期間の開始",
          "period_to": "期間の終了",
          "title": "プロジェクト名",
          "description": "業務内容",
          "role_scale": "役割・規模",
          "languages": "使用言語",
          "db": "DB",
          "server_os": "サーバOS",
          "tools": "FW・MW・ツール等",
          "phases": {"要件定義": false, "基本設計": false, "詳細設計": false, "実装・単体": false, "結合テスト": false, "総合テスト": false, "保守・運用": false}
        }
      ]
    }

    【最重要・厳守】文章は添削しない。要約・言い換え・誤字修正・表現の改善は **一切しない**。
    元の文言・改行・記号・全角半角を保持する。やってよいのは「振り分け(認識)」と「機械的な分割」だけ。

    【やってよい認識・整理（添削ではない）】
    - title: プロジェクト名のみ。先頭の「■」や記号は外して名称だけにする(文章は変えない)。長い補足は description へ。
    - description(業務内容): **必ず ≪案件概要≫ / ≪担当業務≫ / ≪コメント≫ の3見出しに整形**して出力する。
      元データが <担当業務> <習得スキル> <コメント> や ≪習得スキル≫ 等の別見出しでも、内容を見て上記3つに振り分ける:
        ・概要文 → ≪案件概要≫
        ・やった作業・担当・習得スキル → ≪担当業務≫(必要なら 【UI】【API】等の小見出し＋「・項目」の箇条書き)
        ・所感・成果 → ≪コメント≫
      見出し記号は ≪≫ に統一してよい(これは整形であり添削ではない)。ただし **各文・単語・箇条書きの文言自体は一字一句そのまま**。
    - **≪コメント≫ は絶対に省略・要約・空欄にしない**。元データに所感・成果・コメントに当たる文があれば、**全文をそのまま ≪コメント≫ に入れる**。
      元が既に ≪コメント≫ を持つ場合はその中身を1文字も削らず保持する。担当業務・コメントを含め、元の情報を1つも捨てないこと。
    - languages / db / server_os / tools: 元の「使用言語」「DB」等の記載を、**1技術1行(改行区切り)** に分割して該当ラベルへ振り分ける
      (例: "JavaScript TypeScript Ruby" → 3行に分割)。技術名の綴りは変えない(正規化しない)。"Ruby on Rails" 等スペース込みの名前は分割しない。
    【禁止】上記以外の文章の書き換え・要約・誤字修正・順序入れ替え。値の創作。
    - 読み取れない項目だけ空文字 ""。
    - phases は担当工程に ● や ○ が付いている工程を true、空欄を false。
    - projects は CSV の並び順を保つ。
  SYS

  def initialize(spreadsheet_url:, user: nil)
    @spreadsheet_url = spreadsheet_url.to_s.strip
    @user = user
    @spreadsheet_id = extract_id(@spreadsheet_url)
    @gid = extract_gid(@spreadsheet_url)
  end

  attr_reader :spreadsheet_id, :gid

  def call
    raw = fetch_csv
    structured = structure(raw)
    {
      spreadsheet_id: @spreadsheet_id,
      gid: @gid,
      raw_content: raw,
      structured: structured
    }
  end

  private

  def extract_id(url)
    m = url.match(%r{/spreadsheets/d/([a-zA-Z0-9_-]+)})
    raise "スプレッドシートの URL が不正です" unless m
    m[1]
  end

  def extract_gid(url)
    url[/[?#&]gid=(\d+)/, 1] || "0"
  end

  # 公開シートを gviz CSV で取得。リダイレクトを追う。失敗したら OAuth 読み取り。
  def fetch_csv
    csv = fetch_public_csv
    return csv if csv.present?
    fetch_via_oauth
  rescue => e
    raise "シートの読み取りに失敗しました: #{e.message}"
  end

  def fetch_public_csv
    url = "https://docs.google.com/spreadsheets/d/#{@spreadsheet_id}/gviz/tq?tqx=out:csv&gid=#{@gid}"
    body = http_get_follow(url)
    # 非公開だと HTML のログインページが返る。CSV らしさを簡易判定。
    return nil if body.nil? || body.lstrip.start_with?("<")
    body
  rescue
    nil
  end

  def http_get_follow(url, limit = 5)
    raise "リダイレクトが多すぎます" if limit <= 0
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = (uri.scheme == "https"); _1.read_timeout = 30 }
    res = http.get(uri.request_uri)
    case res
    when Net::HTTPSuccess then res.body.force_encoding("UTF-8")
    when Net::HTTPRedirection then http_get_follow(res["location"], limit - 1)
    else nil
    end
  end

  # OAuth で Sheets API から値を読み、CSV 文字列に変換。
  # 操作者にトークンが無ければ admin(西野) のトークンにフォールバック。
  def fetch_via_oauth
    require "google/apis/sheets_v4"
    service = Google::Apis::SheetsV4::SheetsService.new
    service.authorization = GoogleAuth.build_with_fallback(@user)
    spreadsheet = service.get_spreadsheet(@spreadsheet_id)
    sheet = spreadsheet.sheets.find { |s| s.properties.sheet_id.to_s == @gid } || spreadsheet.sheets.first
    title = sheet.properties.title
    rows = service.get_spreadsheet_values(@spreadsheet_id, "#{title}!A1:Z200").values || []
    CSV.generate { |csv| rows.each { |r| csv << r } }
  end

  def structure(raw)
    api_key = OpenaiClient.api_key_for(@user)
    data = OpenaiJson.chat_json(
      system: STRUCTURE_INSTRUCTION,
      user: "次の CSV を構造化してください:\n\n#{raw}",
      api_key: api_key,
      model: "gpt-4o" # mini は長いコメントを省略するため、取りこぼし防止に 4o を使う
    )
    normalize(data)
  end

  def normalize(data)
    data = data.to_h
    data["projects"] = Array(data["projects"]).map { |p| p.to_h }
    data
  end
end
