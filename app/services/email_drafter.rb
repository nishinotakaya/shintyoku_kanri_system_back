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
      invoice_total = @context[:total].to_i
      expense_total = @context[:expense_total].to_i
      grand_total = (@context[:grand_total].to_i.nonzero?) || (invoice_total + expense_total)
      <<~PROMPT
        以下情報で、株式会社ラボップ (#{ @context[:recipient_name] || "ご担当者" }様) 宛に
        #{kind_label}と立替金資料を送付するメール下書きを作って。
        - 対象: #{@context[:year]}年#{@context[:month]}月分
        - 添付: ラボップ宛 請求書 PDF / 立替金 PDF / 立替金 Excel#{ @context[:extra_attachments] ? "（領収書ほか）" : "" }
        - 請求書合計（税込）: ¥#{invoice_total}
        - 立替金合計: ¥#{expense_total}
        - 総額: ¥#{grand_total}
        - 申請者: #{@context[:applicant_name]}
        本文には添付ファイルがあること、請求書合計と立替金合計を分けて記載しご確認お願いしたい旨、
        何かあれば連絡ください、を含めて。金額は ¥X,XXX,XXX のようにカンマ区切りで。
      PROMPT
    when :purchase_order
      <<~PROMPT
        以下情報で、川村卓也様 宛に発注書を送付するメール下書きを作って。
        - 件名候補: #{@context[:subject] || "発注書送付の件"}
        - 注文番号: #{@context[:order_no]}
        - 添付: 発注書 PDF
        本文には添付ファイル確認のお願いと、何かあれば連絡ください、を含めて。
      PROMPT
    when :self_invoice
      cat_label = @context[:category_label].to_s
      include_expense = @context[:include_expense]
      invoice_total = @context[:total].to_i
      expense_total = @context[:expense_total].to_i
      grand_total = (@context[:grand_total].to_i.nonzero?) || (invoice_total + expense_total)
      recipient = @context[:recipient_name].to_s.presence || "ご担当者"
      <<~PROMPT
        以下情報で、#{recipient}様 宛に
        #{cat_label}案件の請求書#{include_expense ? "・立替金資料" : ""}を送付するメール下書きを作って。
        - 対象: #{@context[:year]}年#{@context[:month]}月分（#{cat_label}）
        - 添付: 請求書 PDF#{include_expense ? " / 立替金 PDF / 立替金 Excel" : ""}
        - 請求金額（税込）: ¥#{invoice_total}
        #{include_expense ? "- 立替金合計: ¥#{expense_total}" : ""}
        #{include_expense ? "- 総額: ¥#{grand_total}" : ""}
        - 差出人: #{@context[:sender_name]}
        件名は「【ご請求】#{@context[:year]}年#{@context[:month]}月分 #{cat_label}案件 請求書送付の件」のような形式で。
        本文の宛名行は必ず「#{recipient}様」で始めること。
        本文には添付ファイル確認のお願い + 金額（カンマ区切り）+ ご不明点あればご連絡ください、を含めて。
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
      invoice_total = @context[:total].to_i
      expense_total = @context[:expense_total].to_i
      grand_total = (@context[:grand_total].to_i.nonzero?) || (invoice_total + expense_total)
      fmt = ->(n) { "¥#{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}" }
      {
        subject: "【ご請求】#{@context[:year]}年#{@context[:month]}月分 #{kind_label}送付",
        body: <<~BODY
          株式会社ラボップ
          #{ @context[:recipient_name] || "ご担当者" } 様

          いつもお世話になっております。#{sender}でございます。
          #{@context[:year]}年#{@context[:month]}月分の#{kind_label}関連資料を送付いたします。

          ・請求書合計（税込）: #{fmt.call(invoice_total)}
          ・立替金合計        : #{fmt.call(expense_total)}
          ・総額              : #{fmt.call(grand_total)}

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
    when :self_invoice
      sender = @context[:sender_name].to_s
      cat_label = @context[:category_label].to_s
      include_expense = @context[:include_expense]
      invoice_total = @context[:total].to_i
      expense_total = @context[:expense_total].to_i
      grand_total = (@context[:grand_total].to_i.nonzero?) || (invoice_total + expense_total)
      fmt = ->(n) { "¥#{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}" }
      kind_phrase = include_expense ? "請求書および立替金資料" : "請求書"
      attachments_block = if include_expense
        "添付ファイル:\n  ・請求書 PDF\n  ・立替金 PDF\n  ・立替金 Excel"
      else
        "添付ファイル: 請求書 PDF"
      end
      amount_block = if include_expense
        "・請求金額（税込）: #{fmt.call(invoice_total)}\n・立替金合計        : #{fmt.call(expense_total)}\n・総額              : #{fmt.call(grand_total)}"
      else
        "・請求金額（税込）: #{fmt.call(invoice_total)}"
      end
      {
        subject: "【ご請求】#{@context[:year]}年#{@context[:month]}月分 #{cat_label}案件 #{kind_phrase}送付の件",
        body: <<~BODY
          #{ @context[:recipient_name] || "ご担当者" } 様

          いつもお世話になっております。#{sender}でございます。
          #{@context[:year]}年#{@context[:month]}月分（#{cat_label}）の#{kind_phrase}を送付いたします。

          #{amount_block}

          #{attachments_block}

          ご確認のほどよろしくお願いいたします。
          ご不明点ございましたら、ご連絡ください。

          敬具
          #{sender}
        BODY
      }
    else
      { subject: "送付の件", body: "ご確認のほどよろしくお願いいたします。" }
    end
  end
end
