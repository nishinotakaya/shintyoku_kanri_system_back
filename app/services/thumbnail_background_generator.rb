# gpt-image-1 でサムネの「背景画像」(文字なし)を生成し、PNG バイナリ文字列を返す。
# 文字はフロントの Canvas で後から合成する方針(日本語が崩れないため)。
class ThumbnailBackgroundGenerator
  IMAGES_URL = "https://api.openai.com/v1/images/generations".freeze
  MODEL = ENV.fetch("OPENAI_IMAGE_MODEL", "gpt-image-1").freeze
  SIZE  = "1536x1024".freeze # 16:9 に近い横長

  def initialize(user:)
    @user = user
  end

  # prompt をそのまま渡す(フロントで編集されたプロンプトを受け取る)。
  # => PNG のバイナリ文字列
  def call(prompt:)
    raise "プロンプトが空です" if prompt.to_s.strip.empty?
    api_key = OpenaiClient.api_key_for(@user)
    raise "OpenAI API キーが未設定です。設定画面で登録してください。" if api_key.blank?

    uri = URI(IMAGES_URL)
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 180 }
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{api_key}"
    req.body = { model: MODEL, prompt: prompt, n: 1, size: SIZE }.to_json

    res = http.request(req)
    raise "画像生成エラー (#{res.code}): #{res.body.to_s.slice(0, 300)}" unless res.code.start_with?("2")

    data = JSON.parse(res.body).dig("data", 0)
    # gpt-image-1 は b64_json で返る。dall-e 互換で url が返る場合にも対応。
    if data["b64_json"].present?
      Base64.decode64(data["b64_json"])
    elsif data["url"].present?
      URI.open(data["url"], &:read) # rubocop:disable Security/Open
    else
      raise "画像データが取得できませんでした"
    end
  end
end
