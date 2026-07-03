# OpenAI Chat Completions に system/user を投げて JSON を受け取る共通ヘルパー。
# response_format: json_object を使うので、プロンプトに「JSON で出力」と明記すること。
module OpenaiJson
  module_function

  def chat_json(system:, user:, api_key:, model: nil, temperature: 0.2)
    raise "OpenAI API キーが未設定です。設定画面で登録してください。" if api_key.blank?

    uri = URI("https://api.openai.com/v1/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 120 }
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{api_key}"
    req.body = {
      model: model || ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"),
      messages: [
        { role: "system", content: system },
        { role: "user",   content: user }
      ],
      temperature: temperature,
      response_format: { type: "json_object" }
    }.to_json

    res = http.request(req)
    unless res.code.start_with?("2")
      raise "OpenAI エラー (#{res.code}): #{res.body.to_s.slice(0, 200)}"
    end
    content = JSON.parse(res.body).dig("choices", 0, "message", "content").to_s
    JSON.parse(content)
  end

  # text を返すだけのプレーンな chat (添削など)。
  def chat_text(system:, user:, api_key:, model: nil, temperature: 0.3)
    raise "OpenAI API キーが未設定です。設定画面で登録してください。" if api_key.blank?

    uri = URI("https://api.openai.com/v1/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 120 }
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{api_key}"
    req.body = {
      model: model || ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"),
      messages: [
        { role: "system", content: system },
        { role: "user",   content: user }
      ],
      temperature: temperature
    }.to_json

    res = http.request(req)
    unless res.code.start_with?("2")
      raise "OpenAI エラー (#{res.code}): #{res.body.to_s.slice(0, 200)}"
    end
    JSON.parse(res.body).dig("choices", 0, "message", "content").to_s.strip
  end
end
