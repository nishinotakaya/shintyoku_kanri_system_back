require "json"
require "net/http"
require "uri"
require "base64"

# マイナンバーカード(個人番号カード)の表面・裏面の写真を OpenAI vision で読み取り、
# 個人番号と生年月日を返す。画像はメモリ上で読むだけで保存しない。
# 期待出力:
#   - my_number:       個人番号12桁 (読み取れなければ nil)
#   - my_number_valid:  チェックデジットまで合っているか
#   - birth_date:       生年月日 (Date。和暦は西暦に変換)
#   - name:             氏名
#   - address:          住所
#   - confidence:        読み取りの確信度 (0-100)
class MyNumberCardReader
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  # gpt-5 系は temperature の変更を受け付けないため、リクエストには含めない。
  MODEL = ENV.fetch("EXPENSE_READER_MODEL", "gpt-5.5").freeze

  # images: [{ bytes:, content_type: }] 表面・裏面の1〜2枚
  def self.call(images)
    new(images).call
  end

  def initialize(images)
    @images = Array(images)
  end

  def call
    api_key = ENV["OPENAI_API_KEY"].to_s
    return { error: "OPENAI_API_KEY 未設定" } if api_key.blank?
    return { error: "マイナンバーカードの画像を添付してください" } if @images.blank?

    body = {
      model: MODEL,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: [
          { type: "text", text: "このマイナンバーカードの表面・裏面を読み取って JSON で返してください。" }
        ] + image_url_parts }
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
    # 個人番号そのものはログに出さず、末尾4桁だけ記録する
    Rails.logger.info("[MyNumberCardReader] model=#{MODEL} my_number_last4=#{MyNumber.last4(result[:my_number]).inspect} " \
      "valid=#{result[:my_number_valid]} birth_date=#{result[:birth_date]} confidence=#{result[:confidence]}")
    result
  end

  private

  SYSTEM_PROMPT = <<~SYS.freeze
    あなたはマイナンバーカード(個人番号カード)の写真を読み取るアシスタントです。
    表面(氏名・住所・生年月日・性別)と裏面(個人番号12桁)を読み取り、次の JSON で返してください:
    {
      "my_number": "個人番号12桁の数字 (読み取れなければ null)",
      "birth_date": "生年月日 YYYY-MM-DD (読み取れなければ null。和暦表記なら西暦に変換すること。例: 平成2年9月30日→1990-09-30)",
      "name": "氏名 (読み取れなければ null)",
      "address": "住所 (読み取れなければ null)",
      "confidence": "読み取りの確信度 0-100"
    }
    【個人番号の読み取りについて】
    - 個人番号は裏面の「個人番号」欄に印字された12桁の数字のみを読む
    - 有効期限やQRコード周辺の数字、表面の番号などと混同しないこと
    - 12桁として読み取れない場合は my_number を null にする
    【カードでない写真の場合】
    - マイナンバーカード(個人番号カード)が写っていない写真であれば、全ての項目を null にする
  SYS

  def image_url_parts
    @images.map do |image|
      content_type = image[:content_type].presence || "image/jpeg"
      data_url = "data:#{content_type};base64,#{Base64.strict_encode64(image[:bytes])}"
      { type: "image_url", image_url: { url: data_url, detail: "high" } }
    end
  end

  def normalize(parsed)
    my_number = MyNumber.normalize(parsed["my_number"])
    birth_date = begin
      Date.iso8601(parsed["birth_date"].to_s)
    rescue ArgumentError, TypeError
      nil
    end
    {
      my_number: my_number,
      my_number_valid: my_number.present? && MyNumber.valid?(my_number),
      birth_date: birth_date,
      name: parsed["name"].to_s.strip.presence,
      address: parsed["address"].to_s.strip.presence,
      confidence: parsed["confidence"].to_i.clamp(0, 100)
    }
  end
end
