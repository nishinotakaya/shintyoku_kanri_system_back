require "json"
require "net/http"
require "uri"
require "base64"

# レシート画像を OpenAI(gpt-4o vision) で読み取り、経費データに構造化する。
# 期待出力:
#   - expense_date: 利用日 (ISO 8601)
#   - store_name:   店名
#   - amount:       税込合計(円・整数)
#   - tax_rate:     10 / 8(軽減税率) / 0
#   - account_category: 勘定科目(BusinessExpense::ACCOUNT_CATEGORIES から選択)
#   - memo:         品目の要約(20字程度)
#   - confidence:   分類の確信度(0-100)
class ReceiptExtractor
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def self.call(image_bytes, content_type)
    new(image_bytes, content_type).call
  end

  def initialize(image_bytes, content_type)
    @image_bytes = image_bytes
    @content_type = content_type.presence || "image/jpeg"
  end

  def call
    api_key = ENV["OPENAI_API_KEY"].to_s
    return { error: "OPENAI_API_KEY 未設定" } if api_key.blank?

    data_url = "data:#{@content_type};base64,#{Base64.strict_encode64(@image_bytes)}"
    body = {
      model: "gpt-4o",
      temperature: 0.1,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: [
          { type: "text", text: "このレシートを読み取って JSON で返してください。" },
          { type: "image_url", image_url: { url: data_url, detail: "high" } }
        ] }
      ]
    }

    uri = URI.parse(CHAT_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 90
    request = Net::HTTP::Post.new(uri.path, {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{api_key}"
    })
    request.body = body.to_json
    response = http.request(request)
    raise "OpenAI API error: #{response.code} #{response.body.to_s[0, 300]}" unless response.code.to_i == 200

    content = JSON.parse(response.body).dig("choices", 0, "message", "content").to_s
    parsed = JSON.parse(content) rescue {}
    normalize(parsed)
  end

  private

  SYSTEM_PROMPT = <<~SYS.freeze
    あなたは日本のレシート/領収書を読み取り、個人事業主の経費データに構造化する会計アシスタントです。
    次の JSON で返してください:
    {
      "expense_date": "YYYY-MM-DD (レシートの日付。不明なら null)",
      "store_name": "店名・支払先 (不明なら null)",
      "amount": 税込合計金額の整数 (円。不明なら null),
      "tax_rate": 10 or 8 or 0 (軽減税率対象(飲食料品の持ち帰り等)なら8。混在時は合計額の主となる税率),
      "account_category": "勘定科目 (下のリストから最も適切な1つ)",
      "memo": "品目の要約 (例: 打合せコーヒー2名 / 書籍1冊。20字程度)",
      "confidence": 勘定科目分類の確信度 0-100
    }
    【勘定科目リスト】
    租税公課 / 荷造運賃 / 水道光熱費 / 旅費交通費 / 通信費 / 広告宣伝費 / 接待交際費 /
    損害保険料 / 修繕費 / 消耗品費 / 減価償却費 / 福利厚生費 / 給料賃金 / 外注工賃 /
    利子割引料 / 地代家賃 / 貸倒金 / 会議費 / 新聞図書費 / 支払手数料 / 車両費 / 雑費
    【分類の目安】
    - 飲食店・居酒屋・手土産(取引先との飲食が推定される) → 接待交際費
    - カフェ・喫茶での少額飲食(打合せ・作業) → 会議費
    - 電車・バス・タクシー・高速代・コインパーキング → 旅費交通費
    - ガソリンスタンド・洗車・カー用品 → 車両費
    - 文房具・電池・PC周辺機器・Amazon等の物品(10万円未満) → 消耗品費
    - 書籍・雑誌・技術書・Kindle → 新聞図書費
    - 携帯・ネット回線・サーバー代・クラウド利用料 → 通信費
    - 切手・宅配便 → 荷造運賃
    - 銀行手数料・振込手数料 → 支払手数料
    - 迷ったら 雑費 にし confidence を低くする
    金額は必ず「合計」「お買上げ計」等の税込総額。日付が和暦なら西暦に変換。
  SYS

  def normalize(parsed)
    category = parsed["account_category"].to_s.strip
    category = nil unless BusinessExpense::ACCOUNT_CATEGORIES.include?(category)
    date = (Date.iso8601(parsed["expense_date"].to_s) rescue nil)
    {
      expense_date: date,
      store_name: parsed["store_name"].to_s.strip.presence,
      amount: parsed["amount"].to_s.gsub(/[^\d]/, "").presence&.to_i,
      tax_rate: [ 0, 8, 10 ].include?(parsed["tax_rate"].to_i) ? parsed["tax_rate"].to_i : 10,
      account_category: category,
      memo: parsed["memo"].to_s.strip.presence,
      confidence: parsed["confidence"].to_i.clamp(0, 100),
      raw: parsed
    }
  end
end
