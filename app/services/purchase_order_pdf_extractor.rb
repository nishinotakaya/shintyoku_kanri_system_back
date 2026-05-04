require "pdf/reader"
require "json"
require "net/http"
require "uri"

# 発注書 PDF からテキストを抽出し、OpenAI で構造化 JSON に変換する。
# 期待出力: { order_no, customer_name, subject, period_start, period_end, total_amount, contractor_name }
#
# OPENAI_API_KEY が無い場合はテキスト抽出のみ行い、推測で正規表現フォールバックする。
class PurchaseOrderPdfExtractor
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def self.call(pdf_io_or_path)
    new(pdf_io_or_path).call
  end

  def initialize(pdf_io_or_path)
    @pdf_io_or_path = pdf_io_or_path
  end

  def call
    text = extract_text
    return { error: "PDF からテキストを抽出できませんでした" } if text.blank?

    parsed = call_openai(text) || regex_fallback(text)
    parsed.merge(raw_text: text)
  end

  private

  def extract_text
    reader = if @pdf_io_or_path.respond_to?(:read)
      @pdf_io_or_path.rewind if @pdf_io_or_path.respond_to?(:rewind)
      PDF::Reader.new(@pdf_io_or_path)
    else
      PDF::Reader.new(@pdf_io_or_path)
    end
    reader.pages.map(&:text).join("\n")
  rescue => e
    Rails.logger.warn("[PurchaseOrderPdfExtractor] pdf parse error: #{e.class}: #{e.message}")
    ""
  end

  def call_openai(text)
    api_key = ENV["OPENAI_API_KEY"].to_s
    return nil if api_key.blank?

    sys = <<~SYS
      あなたは日本語ビジネス文書から構造化データを抽出するアシスタントです。
      与えられた発注書 PDF のテキストから次の情報を JSON で抽出してください:
        - order_no: 注文番号 (例: "ORD-010014")。"注文番号"・"発注番号"・"ORD-" 等の語の近傍を探す。見つからなければ null
        - customer_name: 発注元 (例: "タマホーム", "タマリビング", "株式会社ラボップ")。不明なら null
        - subject: 案件名 (例: "タマホーム様電子発注システム開発支援")
        - period_start: 期間開始 ISO8601 (例: "2026-04-01")。不明なら null
        - period_end: 期間終了 ISO8601 (例: "2026-04-30")。不明なら null
        - total_amount: 合計金額 (税込) を整数 (円単位、カンマなし)。不明なら null
        - contractor_name: 受注者 (例: "西野 鷹也", "川村 卓也")。不明なら null
      不明な値は null。文字列はトリム。
      出力は厳密に JSON オブジェクトのみ。
    SYS

    body = {
      model: ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"),
      messages: [
        { role: "system", content: sys },
        { role: "user",   content: text }
      ],
      response_format: { type: "json_object" },
      temperature: 0.0
    }

    uri = URI.parse(CHAT_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 60

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"]  = "application/json"
    req["Authorization"] = "Bearer #{api_key}"
    req.body = body.to_json
    res = http.request(req)
    return nil unless res.code.start_with?("2")

    content = JSON.parse(res.body).dig("choices", 0, "message", "content")
    JSON.parse(content).symbolize_keys
  rescue => e
    Rails.logger.warn("[PurchaseOrderPdfExtractor] openai error: #{e.class}: #{e.message}")
    nil
  end

  # OpenAI 失敗時のフォールバック: 正規表現で order_no と total_amount だけ拾う
  def regex_fallback(text)
    {
      order_no: text[/ORD[-\s]?\d{4,}/]&.gsub(/\s/, ""),
      customer_name: nil,
      subject: nil,
      period_start: nil,
      period_end: nil,
      total_amount: text[/(?:合計|総額|金額)[^\d]{0,8}([\d,]{3,})/, 1]&.delete(",")&.to_i,
      contractor_name: nil
    }
  end
end
