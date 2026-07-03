# OpenAI Text-to-Speech。テキストを人間っぽい高品質な音声(mp3)に変換する。
# YouTubeインタビュー動画用の読み上げに使う。
class OpenaiTts
  MODEL = ENV.fetch("OPENAI_TTS_MODEL", "gpt-4o-mini-tts").freeze
  VOICE = ENV.fetch("OPENAI_TTS_VOICE", "alloy").freeze
  # gpt-4o-mini-tts は instructions で口調を制御できる(語りかけるYouTubeトーン)
  INSTRUCTIONS = "日本語で、YouTubeのインタビュー動画のように、落ち着いて親しみやすく、視聴者に語りかけるトーンで自然に話してください。".freeze
  MAX_CHARS = 4000

  def initialize(user:)
    @user = user
  end

  # text → mp3 のバイナリ文字列
  def synthesize(text)
    body = text.to_s.strip
    raise "読み上げるテキストがありません" if body.empty?
    body = body[0, MAX_CHARS]
    api_key = OpenaiClient.api_key_for(@user)
    raise "OpenAI API キーが未設定です。設定画面で登録してください。" if api_key.blank?

    uri = URI("https://api.openai.com/v1/audio/speech")
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 120 }
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{api_key}"
    payload = { model: MODEL, voice: VOICE, input: body, response_format: "mp3" }
    payload[:instructions] = INSTRUCTIONS if MODEL.include?("gpt-4o")
    req.body = payload.to_json

    res = http.request(req)
    unless res.code.start_with?("2")
      raise "OpenAI TTS エラー (#{res.code}): #{res.body.to_s.slice(0, 200)}"
    end
    res.body
  end
end
