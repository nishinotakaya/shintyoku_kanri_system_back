require "json"
require "net/http"
require "uri"

# 銀行/カード明細の取引行をまとめて AI で勘定科目分類する。
# 入力: [{ date:, description:, amount: }, ...]
# 出力: 各行に { business:(事業経費か), account_category:, memo:, confidence: } を付与して返す
class TransactionCategorizer
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze
  CHUNK = 50

  def self.call(rows)
    new(rows).call
  end

  def initialize(rows)
    @rows = rows
  end

  def call
    api_key = ENV["OPENAI_API_KEY"].to_s
    return @rows.map { |r| r.merge(business: true, account_category: nil, memo: nil, confidence: 0) } if api_key.blank?

    @rows.each_slice(CHUNK).flat_map { |chunk| categorize_chunk(chunk, api_key) }
  end

  private

  SYSTEM_PROMPT = <<~SYS.freeze
    あなたは個人事業主(ITエンジニア)の銀行/カード明細を仕訳する会計アシスタントです。
    与えられた取引リスト(index/日付/摘要/金額)それぞれについて、次の JSON で返してください:
    { "items": [ { "index": 0, "business": true/false, "account_category": "勘定科目", "memo": "内容の推定(15字程度)", "confidence": 0-100 }, ... ] }
    【business の判定】事業に関係しそうな支出は true。明らかに私的(スーパー・美容院・娯楽・保険料(個人)・家賃(自宅で按分不明)等)は false。迷ったら true にして confidence を下げる。
    【勘定科目リスト】租税公課 / 荷造運賃 / 水道光熱費 / 旅費交通費 / 通信費 / 広告宣伝費 / 接待交際費 / 損害保険料 / 修繕費 / 消耗品費 / 減価償却費 / 福利厚生費 / 給料賃金 / 外注工賃 / 利子割引料 / 地代家賃 / 貸倒金 / 会議費 / 新聞図書費 / 支払手数料 / 車両費 / 雑費
    【目安】AWS/GitHub/サーバー/携帯キャリア/プロバイダ→通信費、Amazon/ヨドバシ等の物品→消耗品費、書店/Kindle→新聞図書費、飲食店→接待交際費(取引先)or会議費(カフェ少額)、交通系IC/鉄道/タクシー→旅費交通費、振込手数料/ATM→支払手数料、ガソリン→車両費。
    business=false の行も account_category は最も近いものを入れる(取込時に人が切り替えられるように)。
  SYS

  def categorize_chunk(chunk, api_key)
    listing = chunk.each_with_index.map { |r, i| { index: i, date: r[:date], description: r[:description], amount: r[:amount] } }
    body = {
      model: "gpt-4o-mini",
      temperature: 0.1,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: JSON.generate(listing) }
      ]
    }
    response = post_json(body, api_key)
    parsed = JSON.parse(response.dig("choices", 0, "message", "content").to_s) rescue {}
    by_index = Array(parsed["items"]).index_by { |it| it["index"].to_i }

    chunk.each_with_index.map do |row, i|
      item = by_index[i] || {}
      category = item["account_category"].to_s.strip
      category = nil unless BusinessExpense::ACCOUNT_CATEGORIES.include?(category)
      row.merge(
        business: item.key?("business") ? !!item["business"] : true,
        account_category: category,
        memo: item["memo"].to_s.strip.presence,
        confidence: item["confidence"].to_i.clamp(0, 100)
      )
    end
  end

  def post_json(body, api_key)
    uri = URI.parse(CHAT_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120
    request = Net::HTTP::Post.new(uri.path, { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key}" })
    request.body = body.to_json
    response = http.request(request)
    raise "OpenAI API error: #{response.code}" unless response.code.to_i == 200
    JSON.parse(response.body)
  end
end
