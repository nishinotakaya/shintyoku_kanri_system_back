require "json"
require "net/http"
require "uri"

# 確定申告の年間集計をもとに AI(gpt-4o) が税務アドバイスを返す。
# 出力: { advice: [ { title:, detail: } ... ], summary_note: }
class TaxAdvisor
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def self.call(user:, summary:)
    new(user, summary).call
  end

  def initialize(user, summary)
    @user = user
    @summary = summary
  end

  SYSTEM_PROMPT = <<~SYS.freeze
    あなたは個人事業主(ITエンジニア・青色申告・適格請求書発行事業者)専門の税理士アシスタントです。
    与えられた年間集計(売上/科目別経費/減価償却/所得/消費税概算)を読み、実践的なアドバイスを JSON で返してください:
    { "advice": [ { "title": "見出し(15字以内)", "detail": "端的な説明(80字以内・です/ます調)" }, ... ],
      "summary_note": "全体講評(60字以内)" }
    【観点】※4〜6個に絞る
    - 節税: 使えていない控除/経費の漏れ(家事按分・少額減価償却の特例30万円未満・小規模企業共済/iDeCo等)
    - 消費税: 2割特例と一般課税の有利判定、インボイス(外注先の登録番号確認)
    - 経費バランス: 同業比で不自然に多い/少ない科目、税務調査で見られやすい点(接待交際費など)
    - 期限・手続き: 申告期限、納付方法
    断定しすぎず、金額は集計値を引用して具体的に。免責の但し書きは不要。
  SYS

  def call
    api_key = ENV["OPENAI_API_KEY"].to_s
    return { error: "OPENAI_API_KEY 未設定" } if api_key.blank?

    ct = @summary[:consumption_tax] || {}
    user_prompt = <<~TXT
      【#{@summary[:year]}年 年間集計（#{@user.display_name}）】
      売上(税込): #{@summary[:income_total]}円（うち外注パートナー分の合算: #{@summary[:subcontract_total]}円 → 同額を外注工賃で控除済み）
      経費合計(按分後): #{@summary[:expense_total]}円 / 減価償却: #{@summary[:depreciation_total]}円
      差引所得(青色控除前): #{@summary[:profit]}円
      科目別: #{@summary[:by_category].map { |c| "#{c[:category]}#{c[:total]}円" }.join(" / ")}
      消費税概算: 売上税額#{ct[:sales_tax]}円 / 2割特例納税#{ct[:special20_payment]}円 / 一般課税概算#{ct[:general_estimate]}円
      前提: 青色申告(電子帳簿・e-Tax想定で控除65万円) / 適格請求書発行事業者
    TXT

    body = {
      model: "gpt-4o",
      temperature: 0.3,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: user_prompt }
      ]
    }
    uri = URI.parse(CHAT_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 90
    request = Net::HTTP::Post.new(uri.path, { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key}" })
    request.body = body.to_json
    response = http.request(request)
    raise "OpenAI API error: #{response.code}" unless response.code.to_i == 200

    parsed = JSON.parse(JSON.parse(response.body).dig("choices", 0, "message", "content").to_s) rescue {}
    {
      advice: Array(parsed["advice"]).map { |a| { title: a["title"].to_s, detail: a["detail"].to_s } },
      summary_note: parsed["summary_note"].to_s
    }
  end
end
