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

  # 固定テンプレートを使う種別。AI には文章生成ではなく「誤字脱字校正」だけ依頼
  FIXED_TEMPLATE_KINDS = %i[labop_invoice labop_expense self_invoice].freeze

  def draft
    api_key = ENV["OPENAI_API_KEY"].to_s

    # 請求書系メールは固定テンプレート → AI で誤字校正のみ
    if FIXED_TEMPLATE_KINDS.include?(@kind)
      fixed = fallback
      return fixed if api_key.blank?
      return proofread_typos(api_key, fixed) || fixed
    end

    return fallback if api_key.blank?
    sys = system_prompt
    usr = user_prompt
    body = call_openai(api_key, sys, usr)
    parse(body) || fallback
  rescue => e
    Rails.logger.warn("[EmailDrafter] error: #{e.class}: #{e.message}")
    fallback
  end

  # 固定テンプレートを AI に渡し、誤字脱字のみ修正させる。
  # 構造・改行・記号・数字・宛名は変更不可。失敗 or 大幅改変は nil で fallback させる。
  def proofread_typos(api_key, fixed)
    sys = <<~SYS
      あなたは厳格な日本語ビジネス文書の校正者です。与えられた件名・本文の誤字脱字・タイプミスのみ修正してください。
      ★絶対に変えないルール:
      - 文の構造・敬語表現・語順
      - 改行と空行の位置
      - 句読点の位置
      - 数字、通貨記号「¥」、カンマ
      - 宛名行・添付に関する記述・件名の固定句
      誤字が無ければ入力をそのまま返してください。出力は厳密に JSON のみ:
        {"subject": "件名", "body": "本文"}
    SYS
    usr = <<~USR
      件名:
      #{fixed[:subject]}

      本文:
      #{fixed[:body]}
    USR
    res = call_openai(api_key, sys, usr)
    parsed = parse(res)
    return nil unless parsed
    # 安全策: 文字数が大幅に変わったら採用しない (±20% 以上ずれたら fallback)
    return nil if parsed[:body].length > fixed[:body].length * 1.2 || parsed[:body].length < fixed[:body].length * 0.8
    parsed
  rescue => e
    Rails.logger.warn("[EmailDrafter] proofread error: #{e.class}: #{e.message}")
    nil
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
      sender_name = @context[:sender_name].to_s
      labop_recipient_raw = (@context[:recipient_name].to_s.presence || "御中")
      labop_recipient = labop_recipient_raw.end_with?("御中") ? "#{I18n.t("companies.labop.name")} #{labop_recipient_raw}" : "#{I18n.t("companies.labop.name")} #{labop_recipient_raw}様"
      <<~PROMPT
        以下情報で、#{labop_recipient} 宛に
        #{kind_label}と立替金資料を送付するメール下書きを作って。
        宛名行は必ず「#{labop_recipient}」で始めること（御中の場合は「様」を付けない）。件名に「ご担当者」「担当者」は含めないこと。
        - 対象: #{@context[:year]}年#{@context[:month]}月分
        - 添付: ラボップ宛 請求書 PDF / 立替金 PDF / 立替金 Excel#{ @context[:extra_attachments] ? "（領収書ほか）" : "" }
        - 請求書合計（税込）: ¥#{invoice_total}
        - 立替金合計: ¥#{expense_total}
        - 総額: ¥#{grand_total}
        - 申請者(資料の作成元): #{@context[:applicant_name]}
        - 差出人(メール送信者): #{sender_name}
        ★重要: 本文の自己紹介と署名は必ず「#{sender_name}」で書くこと。
        申請者名(#{@context[:applicant_name]})を自己紹介・署名に使ってはいけない。
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
      recipient = @context[:recipient_name].to_s.presence || "御中"
      # recipient が「御中」で終わるなら様付けしない（会社宛）、それ以外は様付け（個人宛）
      recipient_with_honorific = recipient.end_with?("御中") ? recipient : "#{recipient}様"
      sender_surname = @context[:sender_name].to_s.split(/[\s　]/).first.to_s
      <<~PROMPT
        以下情報で、#{recipient_with_honorific} 宛に
        #{cat_label}案件の請求書#{include_expense ? "・立替金資料" : ""}を送付するメール下書きを作って。
        - 対象: #{@context[:year]}年#{@context[:month]}月分（#{cat_label}）
        - 添付: 請求書 PDF#{include_expense ? " / 立替金 PDF / 立替金 Excel" : ""}
        - 請求金額（税込）: ¥#{invoice_total}
        #{include_expense ? "- 立替金合計: ¥#{expense_total}" : ""}
        #{include_expense ? "- 総額: ¥#{grand_total}" : ""}
        - 差出人: #{@context[:sender_name]}
        件名は「【ご請求】#{@context[:year]}年#{@context[:month]}月分 #{sender_surname}#{cat_label}案件 #{include_expense ? "請求書および立替金資料" : "請求書"}送付の件」の形式で必ず作ること。件名に「ご担当者」「担当者」は含めないこと。
        本文の宛名行は必ず「#{recipient_with_honorific}」で始めること（御中の場合は「様」を付けない）。
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
      # 一括送付: 申請者(applicant) ベースで件名生成（例: 川村Tama案件）
      applicant_surname = @context[:applicant_name].to_s.split(/[、,\s　]/).reject(&:empty?).first.to_s
      applicant_surname = "申請者" if applicant_surname.empty?
      cat_label = @context[:category_label].to_s.presence || ""
      invoice_total = @context[:total].to_i
      expense_total = @context[:expense_total].to_i
      grand_total = (@context[:grand_total].to_i.nonzero?) || (invoice_total + expense_total)
      include_expense = @context[:expense_count].to_i > 0 && expense_total > 0
      build_invoice_email(name_for_subject: applicant_surname, cat_label: cat_label, invoice_total: invoice_total, expense_total: expense_total, grand_total: grand_total, include_expense: include_expense)
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
      sender_surname = sender.split(/[\s　]/).first.to_s
      cat_label = @context[:category_label].to_s
      include_expense = @context[:include_expense]
      invoice_total = @context[:total].to_i
      expense_total = @context[:expense_total].to_i
      grand_total = (@context[:grand_total].to_i.nonzero?) || (invoice_total + expense_total)
      build_invoice_email(name_for_subject: sender_surname, cat_label: cat_label, invoice_total: invoice_total, expense_total: expense_total, grand_total: grand_total, include_expense: include_expense)
    else
      { subject: "送付の件", body: "ご確認のほどよろしくお願いいたします。" }
    end
  end

  # 請求書送付メールの固定テンプレート (self_invoice / labop_invoice 共通)
  # 件名: 【ご請求】{year}年{month}月分 {name}{cat}案件 ...送付の件
  # 本文: 株式会社ラボップ 御中 〜 何卒よろしくお願い申し上げます。
  def build_invoice_email(name_for_subject:, cat_label:, invoice_total:, expense_total:, grand_total:, include_expense:)
    fmt = ->(n) { sign = n.to_i < 0 ? "-" : ""; "#{sign}¥#{n.to_i.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}" }

    # 宛名行: 「株式会社ラボップ 御中」が無ければ補完して整形
    recipient_raw = @context[:recipient_name].to_s.strip
    recipient_raw = "#{I18n.t("companies.labop.name")} #{I18n.t("companies.labop.honorific_default")}" if recipient_raw.empty?
    recipient_line = if recipient_raw.start_with?("株式会社")
      recipient_raw.end_with?("御中") ? recipient_raw : "#{recipient_raw} 様"
    else
      recipient_raw.end_with?("御中") ? "#{I18n.t("companies.labop.name")} #{recipient_raw}" : "#{I18n.t("companies.labop.name")} #{recipient_raw} 様"
    end

    kind_phrase_subject = include_expense ? "請求書および立替金資料送付の件" : "請求書送付の件"
    kind_phrase_body    = include_expense ? "請求書および立替金資料" : "請求書"

    cat_block = cat_label.empty? ? "" : "#{cat_label}案件の"
    subject_cat_block = cat_label.empty? ? "" : "#{cat_label}案件 "

    sender_surname = @context[:sender_name].to_s.split(/[\s　]/).first.to_s
    intro_line = sender_surname.empty? ? "" : "\n#{sender_surname}でございます。"

    breakdown_items = Array(@context[:breakdown_items]).select { |it| it[:label].to_s.strip.length > 0 }
    amount_block = if breakdown_items.any?
      list = breakdown_items.map { |it| "・#{it[:label]}：#{fmt.call(it[:amount])}" }.join("\n")
      <<~AMT.strip
        請求金額（税込）の内訳は以下の通りです。

        #{list}

        合計 請求金額（税込）：#{fmt.call(grand_total)}
      AMT
    elsif include_expense
      <<~AMT.strip
        請求金額（税込）は #{fmt.call(invoice_total)}
        立替金合計は #{fmt.call(expense_total)}、
        総額は #{fmt.call(grand_total)} となります。
      AMT
    else
      "請求金額（税込）は #{fmt.call(invoice_total)} となります。"
    end

    {
      subject: "【ご請求】#{@context[:year]}年#{@context[:month]}月分 #{name_for_subject}#{subject_cat_block}#{kind_phrase_subject}",
      body: <<~BODY
        #{recipient_line}

        お世話になっております。#{intro_line}

        #{cat_block}#{@context[:year]}年#{@context[:month]}月分の#{kind_phrase_body}を送付いたしますので、添付ファイルをご確認ください。

        #{amount_block}

        ご不明点がございましたら、ご連絡ください。
        何卒よろしくお願い申し上げます。
      BODY
    }
  end
end
