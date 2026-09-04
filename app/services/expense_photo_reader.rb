require "json"
require "net/http"
require "uri"
require "base64"

# 実費レシート(高速代・駐車場代・ガソリン代など)の写真を OpenAI vision で読み取り、金額を返す。
# カレンダーの稼働報告書(運送)で「高速代・駐車場代など実費」を写真から自動入力するために使う。
# 期待出力:
#   - amount:     税込合計金額 (円・整数。読み取れなければ nil)
#   - label:      内容の短い表記 (例: "高速代(ETC)" "駐車場代")
#   - confidence: 読み取りの確信度 (0-100)
class ExpensePhotoReader
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  # gpt-5 系は temperature の変更を受け付けないため、リクエストには含めない。
  MODEL = ENV.fetch("EXPENSE_READER_MODEL", "gpt-5.5").freeze

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
      model: MODEL,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: [
          { type: "text", text: "このレシートの金額を読み取って JSON で返してください。" },
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
    result = normalize(parsed)
    Rails.logger.info("[ExpensePhotoReader] model=#{MODEL} amount=#{result[:amount].inspect} label=#{result[:label].inspect} confidence=#{result[:confidence]}")
    result
  end

  private

  SYSTEM_PROMPT = <<~SYS.freeze
    あなたは運送ドライバーの実費レシート写真から金額を読み取るアシスタントです。
    対象は高速道路(ETC利用明細・領収書)・駐車場・ガソリンスタンドなどのレシートです。
    次の JSON で返してください:
    {
      "amount": 税込合計金額の整数 (円。読み取れなければ null),
      "label": 内容の短い表記 (例: "高速代(ETC)", "駐車場代", "ガソリン代"。店名がわかれば "駐車場代(タイムズ)" のように付ける。20字以内),
      "confidence": 読み取りの確信度 0-100
    }
    【読み取りの目安】
    - 「合計」「ご利用額」「領収金額」など税込の支払総額を読む。小計・お預り・お釣りではない
    - 複数の利用明細が並ぶETC明細では合計行を優先する
    - 一部がぼやけていても読める範囲から自信を持って推定できるなら amount を返し、confidence を下げる
    - レシート・領収書が写っていない写真なら amount は null
  SYS

  def normalize(parsed)
    raw_amount = parsed["amount"].to_s.gsub(/[^\d]/, "")
    {
      amount: raw_amount.presence&.to_i,
      label: parsed["label"].to_s.strip.presence,
      confidence: parsed["confidence"].to_i.clamp(0, 100)
    }
  end
end
