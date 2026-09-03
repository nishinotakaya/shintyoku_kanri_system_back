require "json"
require "net/http"
require "uri"
require "base64"

# 車のオドメーター(走行距離計)の写真を OpenAI(gpt-4o vision) で読み取り、km 値を返す。
# カレンダーの稼働報告書(運送)で「開始メーター/終了メーター」を写真から自動入力するために使う。
# 期待出力:
#   - value:      読み取った走行距離 (km・整数。読み取れなければ nil)
#   - confidence: 読み取りの確信度 (0-100)
class MeterPhotoReader
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
      temperature: 0.0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: [
          { type: "text", text: "このメーター写真の走行距離を読み取って JSON で返してください。" },
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
    あなたは車両のメーターパネル写真から走行距離(オドメーター)を読み取るアシスタントです。
    次の JSON で返してください:
    {
      "value": 走行距離の整数 (km。読み取れなければ null),
      "confidence": 読み取りの確信度 0-100
    }
    【読み取りの目安】
    - オドメーター(ODO・総走行距離)の数値を読む。トリップメーター(TRIP A/B)ではない
    - 単位表示が km であることを前提に、数字だけを整数で返す (例: "123456 km" → 123456)
    - 数字の一部が隠れている・ぼやけて確信が持てないときは confidence を低くする
    - メーターが写っていない写真なら value は null
  SYS

  def normalize(parsed)
    raw_value = parsed["value"].to_s.gsub(/[^\d]/, "")
    {
      value: raw_value.presence&.to_i,
      confidence: parsed["confidence"].to_i.clamp(0, 100)
    }
  end
end
