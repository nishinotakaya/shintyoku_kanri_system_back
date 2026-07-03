# タイトル + マインドマップの要点から、サムネ文言(main_copy/highlight_word/sub_copy)を生成する。
class ThumbnailCopywriter
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def initialize(user:)
    @user = user
  end

  # title: 動画タイトル, summary: 内容要点(改行/箇条書き文字列)
  # => { "main_copy" => , "highlight_word" => , "sub_copy" => }
  # current: 既存の下書き(ハッシュ)。渡すと「新規生成」ではなく添削モードになる。
  # proofread: true なら「誤字脱字・表記ゆれのみ」修正(言い回し・意味・長さは変えない)。
  def call(title:, summary:, current: nil, proofread: false)
    api_key = OpenaiClient.api_key_for(@user)
    raise "OpenAI API キーが未設定です。設定画面で登録してください。" if api_key.blank?

    has_draft = current.present? && current.values.any? { |v| v.to_s.strip.present? || (v.is_a?(Array) && v.any? { |x| x.to_s.strip.present? }) }
    user_content =
      if has_draft && proofread
        "次の【下書き】の【誤字脱字・表記ゆれ(全角半角・送り仮名・固有名詞の表記)だけ】を直してください。\n" \
        "★言い回し・語順・意味・長さは一切変えない。煽りや具体性の強化・言い換え・補完はしない。空欄はそのまま空欄で返す。\n" \
        "main_copy/highlight_word/sub_copy/panels(左/中/右) のキーはそのまま、値は誤字脱字を直したものを返す。\n" \
        "# 下書き(JSON)\n#{current.to_json}"
      elsif has_draft
        "次の【下書き】を添削・改善してください。意図は保ったまま、誤字脱字を直し、冗長を削り、" \
        "煽り・本音・具体性を強化し、空欄は補完。main_copy/highlight_word/sub_copy/panels(左/中/右) すべて埋めること。\n" \
        "タイトル: #{title}\n内容の要点:\n#{summary}\n\n# 下書き(JSON)\n#{current.to_json}"
      else
        "タイトル: #{title}\n内容の要点:\n#{summary}"
      end

    uri = URI(CHAT_URL)
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 60 }
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{api_key}"
    system_content = proofread ? ThumbnailPrompts.proofread_system : ThumbnailPrompts.copywriter_system
    req.body = {
      model: OpenaiClient.chat_model,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: system_content },
        { role: "user", content: user_content }
      ]
    }.to_json

    res = http.request(req)
    raise "OpenAI エラー (#{res.code}): #{res.body.to_s.slice(0, 200)}" unless res.code.start_with?("2")

    content = JSON.parse(res.body).dig("choices", 0, "message", "content").to_s
    parsed = JSON.parse(content)
    {
      "main_copy"      => parsed["main_copy"].to_s,
      "highlight_word" => parsed["highlight_word"].to_s,
      "sub_copy"       => parsed["sub_copy"].to_s,
      # 3コマ感情変化サムネ用の各コマの一言（左:自信→中:驚き→右:絶望）
      "panels"         => Array(parsed["panels"]).first(3).map(&:to_s)
    }
  rescue JSON::ParserError => e
    raise "コピー生成の応答を解釈できませんでした: #{e.message}"
  end
end
