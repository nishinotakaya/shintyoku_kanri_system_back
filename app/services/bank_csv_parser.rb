require "csv"
require "json"
require "net/http"
require "uri"
require "digest"

# 銀行/クレジットカードの明細CSVを解析して取引行に正規化する。
# 銀行ごとに列構成が違うため、ヘッダー+サンプル行を AI に渡して列マッピングを推定する。
# 戻り値: { rows: [{ date:, description:, amount:(正=支出), import_hash: }], error: }
class BankCsvParser
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def self.call(bytes)
    new(bytes).call
  end

  def initialize(bytes)
    @bytes = bytes
  end

  def call
    text = to_utf8(@bytes)
    return { error: "CSVを読み取れませんでした" } if text.blank?

    table = parse_csv(text)
    return { error: "CSVの行を解析できませんでした" } if table.size < 2

    mapping = detect_mapping(table)
    return { error: "列構成を判定できませんでした（対応: 日付/摘要/出金 or 支払金額のあるCSV）" } unless mapping

    rows = extract_rows(table, mapping)
    return { error: "支出行が見つかりませんでした" } if rows.empty?

    { rows: rows }
  rescue => e
    { error: "CSV解析エラー: #{e.message}" }
  end

  private

  # 日本の銀行CSVは Shift_JIS(CP932) が多い。UTF-8で不正なら CP932 として変換する。
  def to_utf8(bytes)
    utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
    return utf8.sub(/\A\xEF\xBB\xBF/, "") if utf8.valid_encoding?
    bytes.dup.force_encoding(Encoding::CP932).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  rescue
    nil
  end

  def parse_csv(text)
    CSV.parse(text, liberal_parsing: true).reject { |row| Array(row).compact.all? { |cell| cell.to_s.strip.empty? } }
  end

  # AI にヘッダー+先頭数行を渡して列インデックスを推定させる
  def detect_mapping(table)
    api_key = ENV["OPENAI_API_KEY"].to_s
    return nil if api_key.blank?

    sample = table.first(5).map { |row| row.map(&:to_s) }
    body = {
      model: "gpt-4o-mini",
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: <<~SYS },
          あなたは銀行/クレジットカード明細CSVの列構成を判定するアシスタントです。
          与えられた先頭数行(2次元配列)から次の JSON を返してください（列は0始まりのインデックス）:
          {
            "header_rows": ヘッダー行数(データが始まる前の行数。ヘッダー無しなら0),
            "date_col": 取引日の列,
            "description_cols": [摘要・店名の列(複数可)],
            "out_col": 出金額の列(無ければ null),
            "in_col": 入金額の列(無ければ null),
            "amount_col": 出金/入金が1列にまとまっている場合の列(無ければ null),
            "amount_negative_is_out": amount_col がある場合、マイナス値が支出なら true / プラス値が支出(カード明細等)なら false
          }
          クレジットカード明細(支払金額のみ)は amount_col + amount_negative_is_out=false。
        SYS
        { role: "user", content: JSON.pretty_generate(sample) }
      ]
    }
    response = post_json(body, api_key)
    parsed = JSON.parse(response.dig("choices", 0, "message", "content").to_s) rescue nil
    return nil unless parsed && parsed["date_col"]
    parsed
  end

  def extract_rows(table, mapping)
    data = table.drop(mapping["header_rows"].to_i)
    desc_cols = Array(mapping["description_cols"]).map(&:to_i)
    data.filter_map do |row|
      date = parse_date(row[mapping["date_col"].to_i])
      next unless date
      description = desc_cols.map { |i| row[i].to_s.strip }.reject(&:empty?).join(" ")
      amount = extract_out_amount(row, mapping)
      next unless amount&.positive?
      {
        date: date.iso8601,
        description: description,
        amount: amount,
        import_hash: Digest::SHA1.hexdigest("#{date.iso8601}|#{amount}|#{description}")
      }
    end
  end

  def extract_out_amount(row, mapping)
    if mapping["out_col"]
      to_amount(row[mapping["out_col"].to_i])
    elsif mapping["amount_col"]
      value = to_amount(row[mapping["amount_col"].to_i], allow_negative: true)
      return nil if value.nil?
      if mapping["amount_negative_is_out"]
        value.negative? ? -value : nil
      else
        value.positive? ? value : nil
      end
    end
  end

  def to_amount(cell, allow_negative: false)
    str = cell.to_s.gsub(/[,¥\\\s円"]/, "")
    return nil if str.empty?
    return nil unless str.match?(/\A-?\d+\z/)
    value = str.to_i
    allow_negative ? value : (value.positive? ? value : nil)
  end

  def parse_date(cell)
    str = cell.to_s.strip
    return nil if str.empty?
    # 2026/07/03, 2026-07-03, 20260703, 令和/平成は非対応(実用上まれ)
    if str.match?(/\A\d{8}\z/)
      Date.strptime(str, "%Y%m%d")
    else
      Date.parse(str.tr("年月", "/").tr("日", ""))
    end
  rescue
    nil
  end

  def post_json(body, api_key)
    uri = URI.parse(CHAT_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60
    request = Net::HTTP::Post.new(uri.path, { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key}" })
    request.body = body.to_json
    response = http.request(request)
    raise "OpenAI API error: #{response.code}" unless response.code.to_i == 200
    JSON.parse(response.body)
  end
end
