require "json"
require "net/http"
require "uri"
require "base64"

# 車のオドメーター(走行距離計)の写真を OpenAI vision で読み取り、km 値を返す。
# カレンダーの稼働報告書(運送)で「開始メーター/終了メーター」を写真から自動入力するために使う。
# 期待出力:
#   - value:      読み取った走行距離 (km・整数。読み取れなければ nil)
#   - confidence: 読み取りの確信度 (0-100)
class MeterPhotoReader
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  # ダッシュボード全景の小さな数字を読むため、視覚性能の高い最新モデルを使う。
  # gpt-5 系は temperature の変更を受け付けないため、リクエストには含めない。
  MODEL = ENV.fetch("METER_READER_MODEL", "gpt-5.5").freeze

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
    result = normalize(parsed)
    Rails.logger.info("[MeterPhotoReader] model=#{MODEL} value=#{result[:value].inspect} confidence=#{result[:confidence]}")
    result
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
    - 写真にはスピードメーター・タコメーター・時計・燃料計・警告灯など多くの表示が写り込むことがある。
      その中から「オドメーター(ODO・総走行距離)」だけを探して読む
    - トリップメーター(TRIP A/B)ではない。TRIP は小数点付き(例: 123.4)のことが多く、
      ODO は桁数が多い整数(例: 45678)のことが多い。「ODO」「km」の表記が近くにあればそれを優先
    - 時計(コロン付き 12:34)・スピード表示・燃料残量の数字と混同しない
    - デジタル液晶でもアナログ回転式(ローラー数字)でも読む
    - 数字だけを整数で返す (例: "123456 km" → 123456)
    - 一部がぼやけていても読める桁から自信を持って推定できるなら value を返し、confidence を下げる
    - オドメーターがどこにも写っていない写真なら value は null
  SYS

  def normalize(parsed)
    raw_value = parsed["value"].to_s.gsub(/[^\d]/, "")
    {
      value: raw_value.presence&.to_i,
      confidence: parsed["confidence"].to_i.clamp(0, 100)
    }
  end
end
