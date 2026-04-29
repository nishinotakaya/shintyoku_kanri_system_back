require "net/http"
require "json"
require "uri"

# OpenAI を使ってメールの件名・本文を生成する。
# OPENAI_API_KEY が無ければ簡易テンプレでフォールバック (空文字回避)。
class EmailDrafter
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  # kind: :labop_invoice / :labop_expense / :purchase_order など
  # context: ハッシュ (sender_name, recipient_name, year, month, total, items 等)
  def self.draft(kind:, context: {})
    new(kind: kind, context: context).draft
  end

  def initialize(kind:, context:)
    @kind = kind.to_sym
    @context = context.symbolize_keys
  end

  def draft
    api_key = ENV["OPENAI_API_KEY"].to_s
    return fallback if api_key.blank?

    sys = system_prompt
    usr = user_prompt
    body = call_openai(api_key, sys, usr)
    parse(body) || fallback
  rescue => e
    Rails.logger.warn("[EmailDrafter] error: #{e.class}: #{e.message}")
    fallback
  end

  private

  def system_prompt
    <<~PROMPT
      あなたはビジネスメール下書き支援アシスタント。日本語の丁寧で簡潔なビジネスメールを作る。
      出力は厳密に JSON のみ。
        {"subject": "件名", "body": "本文"}
      本文は宛名行 (例: 株式会社XX 〇〇様) → 挨拶 → 本文 → 結び (敬具) → 署名 の順。
      署名は「#{ @context[:sender_name] || "" }」。
    PROMPT
  end

  def user_prompt
    case @kind
    when :labop_invoice, :labop_expense
      kind_label = @kind == :labop_expense ? "立替金" : "請求書"
      <<~PROMPT
        以下情報で、株式会社ラボップ (#{ @context[:recipient_name] || "ご担当者" }様) 宛に
        #{kind_label}と立替金資料を送付するメール下書きを作って。
        - 対象: #{@context[:year]}年#{@context[:month]}月分
        - 添付: ラボップ宛 請求書 PDF / 立替金 PDF / 立替金 Excel#{ @context[:extra_attachments] ? "（領収書ほか）" : "" }
        - 合計: ¥#{@context[:total].to_i}
        - 申請者: #{@context[:applicant_name]}
        本文には添付ファイルがあること、ご確認お願いしたい旨、何かあれば連絡ください、を含めて。
      PROMPT
    when :purchase_order
      <<~PROMPT
        以下情報で、川村卓也様 宛に発注書を送付するメール下書きを作って。
        - 件名候補: #{@context[:subject] || "発注書送付の件"}
        - 注文番号: #{@context[:order_no]}
        - 添付: 発注書 PDF
        本文には添付ファイル確認のお願いと、何かあれば連絡ください、を含めて。
      PROMPT
    else
      "宛先 #{@context[:recipient_name]} に対する送付メール下書きを作って。本文は丁寧に。"
    end
  end

  def call_openai(api_key, sys, usr)
    uri = URI.parse(CHAT_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"]  = "application/json"
    req["Authorization"] = "Bearer #{api_key}"
    req.body = {
      model: ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"),
      messages: [
        { role: "system", content: sys },
        { role: "user",   content: usr }
      ],
      response_format: { type: "json_object" },
      temperature: 0.4
    }.to_json
    res = http.request(req)
    return nil unless res.code.start_with?("2")
    JSON.parse(res.body).dig("choices", 0, "message", "content")
  end

  def parse(content)
    return nil if content.blank?
    h = JSON.parse(content)
    subject = h["subject"].to_s.strip
    body = h["body"].to_s.strip
    return nil if subject.empty? || body.empty?
    { subject: subject, body: body }
  rescue JSON::ParserError
    nil
  end

  def fallback
    case @kind
    when :labop_invoice, :labop_expense
      kind_label = @kind == :labop_expense ? "立替金" : "請求書"
      sender = @context[:sender_name].to_s
      {
        subject: "【ご請求】#{@context[:year]}年#{@context[:month]}月分 #{kind_label}送付",
        body: <<~BODY
          株式会社ラボップ
          #{ @context[:recipient_name] || "ご担当者" } 様

          いつもお世話になっております。#{sender}でございます。
          #{@context[:year]}年#{@context[:month]}月分の#{kind_label}関連資料を送付いたします。

          添付ファイル:
            ・ラボップ宛 請求書 PDF
            ・立替金 PDF
            ・立替金 Excel

          ご確認のほどよろしくお願いいたします。
          ご不明点ございましたら、ご連絡ください。

          敬具
          #{sender}
        BODY
      }
    when :purchase_order
      sender = @context[:sender_name].to_s
      {
        subject: "【発注書】#{@context[:order_no]} 送付の件",
        body: <<~BODY
          川村 卓也 様

          いつもお世話になっております。#{sender}でございます。
          表題の件、発注書 (#{@context[:order_no]}) を添付にて送付いたします。

          ご確認のほどよろしくお願いいたします。

          敬具
          #{sender}
        BODY
      }
    else
      { subject: "送付の件", body: "ご確認のほどよろしくお願いいたします。" }
    end
  end
end
