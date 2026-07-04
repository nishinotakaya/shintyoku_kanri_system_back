require "net/http"
require "json"

# HeyGen API ラッパー。
# - アバター/ボイス一覧の取得
# - テキスト→トーキング動画の生成 / ステータス取得
# - 写真アップロード(asset) → 本人トーキングフォト作成
#
# キー解決: user.heygen_api_key があればそれ、無ければ ENV["HEY_GEN_API_KEY"](= admin/西野の共通キー)
class HeygenClient
  BASE = "https://api.heygen.com".freeze
  UPLOAD_BASE = "https://upload.heygen.com".freeze

  class Error < StandardError; end

  def self.api_key_for(user)
    user&.heygen_api_key.presence || ENV["HEY_GEN_API_KEY"]
  end

  def initialize(user: nil, api_key: nil)
    @api_key = api_key.presence || self.class.api_key_for(user)
    raise Error, "HeyGen API キーが未設定です。設定画面で登録するか、管理者にお問い合わせください。" if @api_key.blank?
  end

  # 残高(API クレジット)
  def remaining_quota
    get("/v2/user/remaining_quota").dig("data", "remaining_quota")
  end

  # ストックアバター一覧(必要な項目だけ整形)
  def avatars(limit: 60)
    data = get("/v2/avatars")
    (data.dig("data", "avatars") || []).first(limit).map do |a|
      { avatar_id: a["avatar_id"], name: a["avatar_name"], preview: a["preview_image_url"], gender: a["gender"] }
    end
  end

  # 日本語ボイス一覧
  def japanese_voices
    data = get("/v2/voices")
    (data.dig("data", "voices") || [])
      .select { |v| v["language"].to_s.include?("Japanese") }
      .map { |v| { voice_id: v["voice_id"], name: v["name"], gender: v["gender"], preview: v["preview_audio"] } }
  end

  # 動画生成。avatar_kind: "avatar" or "talking_photo"
  # ロボット感を減らす: emotion(抑揚) + speed(話速) + 自然化した台本 + caption(字幕焼込)。
  #   emotion: Excited/Friendly/Serious/Soothing/Broadcaster (対応ボイスのみ有効)
  #   speed:   0.5〜1.5 (1.0が標準。0.9前後で落ち着いた自然な話速)
  # 返り値: HeyGen の video_id
  def generate_video(text:, voice_id:, avatar_kind: "avatar", avatar_id: nil, talking_photo_id: nil,
                     width: 1280, height: 720, emotion: "Friendly", speed: 0.92, caption: true)
    character =
      if avatar_kind == "talking_photo"
        raise Error, "talking_photo_id がありません" if talking_photo_id.blank?
        { type: "talking_photo", talking_photo_id: talking_photo_id }
      else
        raise Error, "avatar_id がありません" if avatar_id.blank?
        { type: "avatar", avatar_id: avatar_id, avatar_style: "normal" }
      end

    voice = { type: "text", input_text: humanize_script(text), voice_id: voice_id }
    voice[:speed] = speed if speed
    voice[:emotion] = emotion if emotion.present?

    payload = {
      video_inputs: [ { character: character, voice: voice } ],
      dimension: { width: width, height: height },
      caption: caption # 字幕を焼き込む
    }
    res = post("/v2/video/generate", payload)
    res.dig("data", "video_id") or raise Error, "video_id が取得できませんでした: #{res.inspect}"
  end

  # 書き言葉→話し言葉寄りに軽く整えてロボット感を減らす。
  # 文末や句読点に自然な間が入るよう調整（過剰な整形はしない）。
  def humanize_script(text)
    text.to_s
        .gsub(/([。！？])(?=\S)/, "\\1 ")   # 文の切れ目に半角スペース=わずかな間
        .gsub(/、/, "、")                     # 読点はそのまま(間として機能)
        .strip
  end

  # 生成ステータス。{status:, video_url:, duration:, error:}
  def video_status(video_id)
    data = get("/v1/video_status.get?video_id=#{video_id}").fetch("data", {})
    {
      status: data["status"],            # pending / processing / completed / failed
      video_url: data["video_url"],
      duration: data["duration"],
      error: data["error"]
    }
  end

  # 音声をアップロードして声をクローンする。返り値: voice_id
  def clone_voice(audio_bytes:, name:, content_type: "audio/wav")
    filename = "voice.#{content_type.split('/').last}"
    res = post_multipart("/v2/voices/clone", { "voice_name" => name }, file_bytes: audio_bytes, file_name: filename, file_type: content_type)
    res.dig("data", "voice_id") or raise Error, "voice_id が取得できませんでした: #{res.inspect}"
  end

  # 声のクローンを削除
  def delete_voice(voice_id)
    delete("/v2/voices/#{voice_id}")
    true
  rescue Error
    false
  end

  # 画像をアップロードしてトーキングフォト化する。
  # 専用窓口 upload.heygen.com/v1/talking_photo が talking_photo_id を返す
  # (汎用 /v1/asset の image_key は talking_photo として使えない＝"avatar look not found" になる)
  # 返り値: { talking_photo_id:, talking_photo_url: }
  def create_talking_photo(image_bytes:, content_type: "image/jpeg")
    uri = URI("#{UPLOAD_BASE}/v1/talking_photo")
    req = Net::HTTP::Post.new(uri)
    req["X-Api-Key"] = @api_key
    req["Content-Type"] = content_type
    req.body = image_bytes.b
    res = parse(http(uri).request(req))
    id = res.dig("data", "talking_photo_id")
    raise Error, "顔写真の登録に失敗しました: #{res.inspect}" if id.blank?
    { talking_photo_id: id, talking_photo_url: res.dig("data", "talking_photo_url") }
  end

  private

  def upload_asset(bytes, content_type)
    uri = URI("#{UPLOAD_BASE}/v1/asset")
    req = Net::HTTP::Post.new(uri)
    req["X-Api-Key"] = @api_key
    req["Content-Type"] = content_type
    req.body = bytes
    parse(http(uri).request(req))
  end

  def get(path)
    uri = URI("#{BASE}#{path}")
    req = Net::HTTP::Get.new(uri)
    req["X-Api-Key"] = @api_key
    req["Accept"] = "application/json"
    parse(http(uri).request(req))
  end

  def delete(path)
    uri = URI("#{BASE}#{path}")
    req = Net::HTTP::Delete.new(uri)
    req["X-Api-Key"] = @api_key
    parse(http(uri).request(req))
  end

  # multipart/form-data でテキストフィールド + ファイル1つを送る
  def post_multipart(path, fields, file_bytes:, file_name:, file_type:)
    uri = URI("#{BASE}#{path}")
    boundary = "----heygen#{object_id}#{file_bytes.bytesize}"
    body = "".b # バイナリで組む(テキストと音声/画像bytesが混在するため)
    fields.each { |k, v| body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n".b }
    body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{file_name}\"\r\nContent-Type: #{file_type}\r\n\r\n".b
    body << file_bytes.b << "\r\n--#{boundary}--\r\n".b
    req = Net::HTTP::Post.new(uri)
    req["X-Api-Key"] = @api_key
    req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    req.body = body
    parse(http(uri).request(req))
  end

  def post(path, payload)
    uri = URI("#{BASE}#{path}")
    req = Net::HTTP::Post.new(uri)
    req["X-Api-Key"] = @api_key
    req["Content-Type"] = "application/json"
    req.body = payload.to_json
    parse(http(uri).request(req))
  end

  def http(uri)
    Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 120 }
  end

  def parse(res)
    body = JSON.parse(res.body) rescue {}
    unless res.code.start_with?("2")
      msg = body.dig("error", "message") || body["message"] || res.body.to_s.slice(0, 200)
      raise Error, "HeyGen エラー (#{res.code}): #{msg}"
    end
    # HeyGen は 200 でも error フィールドに入れてくる場合がある
    if body["error"].is_a?(Hash) && body["error"]["message"].present?
      raise Error, "HeyGen エラー: #{body['error']['message']}"
    end
    body
  end
end
