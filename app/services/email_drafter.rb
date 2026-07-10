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
    when :purchase_order_bulk
      items = Array(@context[:items])
      breakdown = items.map.with_index(1) do |it, i|
        line = "  #{i}. #{it[:subject].presence || '(案件名未設定)'}（#{it[:period_start]}〜#{it[:period_end]} / ¥#{it[:total_amount].to_i}）"
        if it[:hours_per_cycle].to_i > 0
          line += "  月#{it[:hours_per_cycle]}h / 月額 ¥#{it[:monthly_tax_exc].to_i}(税抜) → ¥#{it[:monthly_tax_inc].to_i}(税込) / 時給 ¥#{it[:hourly_tax_exc].to_i}(税抜) → ¥#{it[:hourly_tax_inc].to_i}(税込)"
        end
        line
      end.join("\n")
      grand_total = items.sum { |it| it[:total_amount].to_i }
      monthly_hours_sum   = items.sum { |it| it[:hours_per_cycle].to_i }
      monthly_inc_sum     = items.sum { |it| it[:monthly_tax_inc].to_i }
      monthly_exc_sum     = items.sum { |it| it[:monthly_tax_exc].to_i }
      <<~PROMPT
        以下情報で、川村卓也様 宛に複数の発注書を一括送付するメール下書きを作って。
        - 件数: #{items.size}件
        - 内訳:
        #{breakdown}
        - 1ヶ月あたり合計: 工数 #{monthly_hours_sum}h / 月額 ¥#{monthly_exc_sum}(税抜) → ¥#{monthly_inc_sum}(税込)
        - 全期間 合計金額（税込）: ¥#{grand_total}
        - 添付: 発注書 PDF × #{items.size}件

        ★件名:
        - 形式は「【発注書#{items.size}件】2026年X月〜Y月分 案件名 送付の件」のように、期間（請求月レンジ）と主要案件名を含めること
        - 例: 「【発注書2件】2026年6月〜8月分 タマホーム・タマリビング案件 送付の件」
        - 単月なら「2026年X月分」、複数月なら「2026年X月〜Y月分」

        ★本文の構成:
        1. 「川村卓也様」「お世話になっております。」
        2. 「この度、#{period_label || 'XXXX年X月分'}の発注書を#{items.size}件お送りいたします。」のような導入文
        3. 各案件の詳細（番号付き）: 案件名・期間・1ヶ月あたり工数(h)・月額(税抜と税込)・時給(税抜と税込)・小計(税込)
        4. 「【1ヶ月あたり合計】」セクション: 工数h / 月額(税抜と税込)
        5. 「合計金額（税込）はXXX円となります。」
        6. 添付確認・連絡先案内
        7. 「敬具」「西野 鷹也」
        金額は ¥X,XXX,XXX のカンマ区切り。改行ゆるめで読みやすく。
      PROMPT
    when :payment_notice
      grand_total = @context[:grand_total].to_i
      paid_on = @context[:paid_on].to_s
      sender = @context[:sender_name].to_s
      sender_surname = sender.split(/[\s　]/).first.to_s
      recipient_raw = @context[:recipient_name].to_s.strip.presence || "ご担当者"
      recipient_line = if recipient_raw.end_with?("様", "御中")
        recipient_raw
      elsif recipient_raw.start_with?("株式会社")
        "#{recipient_raw} 御中"
      else
        "#{recipient_raw} 様"
      end
      breakdown = Array(@context[:breakdown_items])
        .select { |it| it[:label].to_s.strip.length > 0 }
        .map { |it| "  ・#{it[:label]}：¥#{it[:amount].to_i}" }
        .join("\n")
      # お振込先: 受取人(申請者)の請求書設定に保存された振込先。空でなければ本文に載せる。
      bank_info = @context[:bank_info].to_s.strip
      bank_block = bank_info.empty? ? "" : "\n        - お振込先:\n#{bank_info.split("\n").map { |line| "          #{line.strip}" }.join("\n")}"
      bank_rule = bank_info.empty? ? "" : "\n        - 「お振込先：」として上記の口座情報を本文の振込金額の近くに、改行を保って明記する（勝手に変えない）"
      <<~PROMPT
        以下情報で、#{recipient_line} 宛に「お振込のご案内」(支払通知書) のメール下書きを作って。
        - 振込日: #{paid_on}
        - 振込金額（税込・合計）: ¥#{grand_total}
        - 内訳:
        #{breakdown}#{bank_block}
        - 差出人: #{sender}
        - 添付: 支払通知書 PDF（請求書と同じレイアウト・タイトルのみ「支払通知書」）

        ★必ず守ること:
        - 件名は「【お振込のご案内】#{@context[:year]}年#{@context[:month]}月分」のような明確な題名にすること（「ご請求」とは絶対に書かない、これは支払い側からの通知）
        - 本文の宛名行は必ず「#{recipient_line}」で始める
        - 自己紹介と署名は必ず「#{sender_surname}」（差出人）で書く
        - 「下記の通りお振込いたしました」「ご確認のほどよろしくお願い申し上げます」のニュアンスを入れる
        - 振込日と振込金額は本文中に明記する（金額は ¥X,XXX,XXX のカンマ区切り）
        - 内訳が複数ある場合は箇条書きで本文に含める#{bank_rule}
        - 添付の支払通知書 PDF にも同内容が記載されている旨を一言添える
        - 「請求」「請求書」「請求金額」という表現は使わない（あくまで支払側からの通知）
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
    when :purchase_order_bulk
      sender = @context[:sender_name].to_s
      items = Array(@context[:items])
      grand_total = items.sum { |it| it[:total_amount].to_i }
      monthly_hours_sum = items.sum { |it| it[:hours_per_cycle].to_i }
      monthly_inc_sum   = items.sum { |it| it[:monthly_tax_inc].to_i }
      monthly_exc_sum   = items.sum { |it| it[:monthly_tax_exc].to_i }
      fmt = ->(n) { "¥#{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}" }

      # 件名用: 「請求月」(締日25基準) を計算して期間レンジを作る
      billing_month = ->(iso) {
        d = Date.parse(iso) rescue nil
        next nil unless d
        d.day <= 25 ? [ d.year, d.month ] : [ (d >> 1).year, (d >> 1).month ]
      }
      starts = items.map { |it| billing_month.call(it[:period_start].to_s) }.compact
      ends   = items.map { |it| billing_month.call(it[:period_end].to_s) }.compact
      first  = starts.min_by { |y, m| y * 12 + m }
      last   = ends.max_by   { |y, m| y * 12 + m }
      period_label =
        if first && last
          if first == last
            "#{first[0]}年#{first[1]}月分"
          elsif first[0] == last[0]
            "#{first[0]}年#{first[1]}月〜#{last[1]}月分"
          else
            "#{first[0]}年#{first[1]}月〜#{last[0]}年#{last[1]}月分"
          end
        else
          ""
        end

      # 件名用案件キーワード: subject の「様」or「（」の前まで、最大3件
      subject_keywords = items
        .map { |it| it[:subject].to_s.split(/様|（|\(/).first.to_s.strip }
        .reject(&:empty?).uniq
      subject_label =
        case subject_keywords.size
        when 0 then ""
        when 1, 2 then "#{subject_keywords.join('・')}案件 "
        else "#{subject_keywords.first(2).join('・')}ほか#{items.size}件 "
        end

      subject_str = "【発注書#{items.size}件】#{period_label} #{subject_label}送付の件".gsub(/ +/, " ").strip

      detail_block = items.map.with_index(1) { |it, i|
        lines = []
        lines << "#{i}. #{it[:subject].presence || '(案件名未設定)'}"
        lines << "   - 期間：#{it[:period_start]}〜#{it[:period_end]}"
        if it[:hours_per_cycle].to_i > 0
          lines << "   - 1ヶ月あたり：#{it[:hours_per_cycle]}h"
          lines << "     - 月額：#{fmt.call(it[:monthly_tax_exc])}（税抜） / #{fmt.call(it[:monthly_tax_inc])}（税込）"
          lines << "     - 時給：#{fmt.call(it[:hourly_tax_exc])}（税抜） / #{fmt.call(it[:hourly_tax_inc])}（税込）"
        end
        lines << "   - 小計（税込）：#{fmt.call(it[:total_amount])}"
        lines.join("\n")
      }.join("\n\n")

      intro = period_label.empty? ? "発注書を#{items.size}件" : "#{period_label}の発注書を#{items.size}件"

      {
        subject: subject_str,
        body: <<~BODY
          川村卓也様

          お世話になっております。

          この度、#{intro}お送りいたします。

          #{detail_block}

          【1ヶ月あたり合計】
          - 工数：#{monthly_hours_sum}h
          - 月額：#{fmt.call(monthly_exc_sum)}（税抜） / #{fmt.call(monthly_inc_sum)}（税込）

          合計金額（税込）は#{fmt.call(grand_total)}となります。

          添付の発注書をご確認いただき、
          何かご不明点等がございましたら、お気軽にご連絡ください。

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
    when :payment_notice
      build_payment_notice_email
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

  # 振込通知 (支払通知書) メールの固定テンプレート
  # context: recipient_name, paid_on (Date or 'YYYY-MM-DD'), grand_total, breakdown_items, sender_name, year, month
  def build_payment_notice_email
    fmt = ->(n) { sign = n.to_i < 0 ? "-" : ""; "#{sign}¥#{n.to_i.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}" }

    recipient_raw = @context[:recipient_name].to_s.strip
    recipient_raw = "ご担当者" if recipient_raw.empty?
    recipient_line = if recipient_raw.end_with?("様", "御中")
      recipient_raw
    elsif recipient_raw.start_with?("株式会社")
      "#{recipient_raw} 御中"
    else
      "#{recipient_raw} 様"
    end

    paid_on_raw = @context[:paid_on].to_s
    paid_on_label = if paid_on_raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      d = Date.parse(paid_on_raw)
      "#{d.year}年#{d.month}月#{d.day}日"
    else
      paid_on_raw
    end

    grand_total = @context[:grand_total].to_i
    sender = @context[:sender_name].to_s
    sender_surname = sender.split(/[\s　]/).first.to_s

    breakdown_items = Array(@context[:breakdown_items]).select { |it| it[:label].to_s.strip.length > 0 }
    breakdown_block = if breakdown_items.any?
      list = breakdown_items.map { |it| "・#{it[:label]}：#{fmt.call(it[:amount])}" }.join("\n")
      <<~BD.strip
        【内訳】
        #{list}
      BD
    else
      ""
    end

    subject_period = if @context[:year] && @context[:month]
      "#{@context[:year]}年#{@context[:month]}月分"
    else
      ""
    end

    # お振込先: 受取人(申請者)の請求書設定 bank_info を自動で載せる。外部APIは使わず保存値を使う。
    bank_info = @context[:bank_info].to_s.strip
    bank_block = bank_info.empty? ? "" : "お振込先：\n#{bank_info.split("\n").map { |line| "　#{line.strip}" }.join("\n")}"

    body_lines = [
      recipient_line,
      "",
      "いつもお世話になっております。#{sender_surname.empty? ? '' : sender_surname + 'でございます。'}",
      "",
      "下記の通りお振込いたしましたので、ご確認のほどよろしくお願い申し上げます。",
      "",
      "━━━━━━━━━━━━━━━━━━━━",
      "振込日　：#{paid_on_label}",
      "振込金額：#{fmt.call(grand_total)}（税込）"
    ]
    body_lines += [ "", bank_block ] unless bank_block.empty?
    body_lines << "━━━━━━━━━━━━━━━━━━━━"
    body_lines += [ "", breakdown_block ] unless breakdown_block.empty?
    body_lines += [
      "",
      "ご不明点がございましたらお知らせください。"
    ]

    {
      subject: "【お振込のご案内】#{subject_period}".strip.sub(/\s+\z/, ""),
      body: body_lines.join("\n") + "\n"
    }
  end
end
