require "pdf/reader"
require "json"
require "net/http"
require "uri"

# 請求書 PDF からテキストを抽出し、OpenAI で構造化 JSON に変換する。
# 期待出力:
#   - partner_name: 取引先（請求先）
#   - subject: 件名
#   - subtotal_amount: 税抜小計（円）
#   - tax_amount: 消費税（円）
#   - total_amount: 税込合計（円）
#   - issue_date: 発行日 (ISO 8601)
#   - due_date: 支払期限 (ISO 8601)
#   - invoice_number: 請求書番号
class InvoicePdfExtractor
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def self.call(pdf_io_or_path)
    new(pdf_io_or_path).call
  end

  def initialize(pdf_io_or_path)
    @pdf_io_or_path = pdf_io_or_path
  end

  def call
    text = extract_text
    return { error: "PDF からテキストを抽出できませんでした", raw_text: "" } if text.blank?

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
    Rails.logger.warn("[InvoicePdfExtractor] pdf parse error: #{e.class}: #{e.message}")
    ""
  end

  def call_openai(text)
    api_key = ENV["OPENAI_API_KEY"].to_s
    return nil if api_key.blank?

    sys = <<~SYS
      あなたは日本語ビジネス文書から構造化データを抽出するアシスタントです。
      与えられた請求書 PDF のテキストから次の情報を JSON で抽出してください:
        - partner_name: 取引先＝請求先の会社名（"御中" の付いている会社、例: "株式会社ラボップ"）。不明なら null
        - subject: 件名（"件名:" の右側、例: "タマホーム様システム保守・開発"）。不明なら null
        - subtotal_amount: 税抜小計を整数（円、カンマなし）。"小計" 行の金額。不明なら null
        - tax_amount: 消費税を整数（円）。"消費税" 行の金額。不明なら null
        - total_amount: 税込合計を整数（円）。"合計" または "ご請求金額" の金額。不明なら null
        - issue_date: 発行日 ISO8601 (例: "2026-02-28")。"YYYY年MM月DD日" 形式から変換。不明なら null
        - due_date: 支払期限 ISO8601 (例: "2026-04-05")。"お支払い期限" の日付。不明なら null
        - invoice_number: 請求書番号（"請求番号:" の右側、例: "202602010301"）。不明なら null
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
    Rails.logger.warn("[InvoicePdfExtractor] openai error: #{e.class}: #{e.message}")
    nil
  end

  # OpenAI 失敗時のフォールバック: 正規表現で取れる範囲だけ拾う
  def regex_fallback(text)
    issue = text[/(\d{4})年(\d{1,2})月(\d{1,2})日/, 0]
    due = text[/お支払い?期限[^\d]{0,8}(\d{4})年(\d{1,2})月(\d{1,2})日/, 0]
    {
      partner_name: text[/(株式会社[^\s\n御]+|[^\s\n]+株式会社)/, 1],
      subject: text[/件名[:：]\s*([^\n]+)/, 1]&.strip,
      subtotal_amount: text[/小計[^\d-]{0,8}([\d,]+)/, 1]&.delete(",")&.to_i,
      tax_amount: text[/消費税[^\d-]{0,15}([\d,]+)/, 1]&.delete(",")&.to_i,
      total_amount: text[/(?:合計|ご請求金額)[^\d¥]{0,8}¥?\s?([\d,]+)/, 1]&.delete(",")&.to_i,
      issue_date: parse_jp_date(issue),
      due_date: parse_jp_date(due&.sub(/お支払い?期限[^\d]*/, "")),
      invoice_number: text[/請求(?:書)?番号[^\d]{0,5}(\d{6,})/, 1]
    }
  end

  def parse_jp_date(jp)
    return nil unless jp
    m = jp.match(/(\d{4})年(\d{1,2})月(\d{1,2})日/)
    return nil unless m
    Date.new(m[1].to_i, m[2].to_i, m[3].to_i).iso8601
  rescue StandardError
    nil
  end
end
