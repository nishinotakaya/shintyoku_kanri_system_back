require "net/http"
require "json"
require "uri"

# LINE Messaging API の push エンドポイントへ通知を送る。
# 必要な ENV:
#   LINE_CHANNEL_ACCESS_TOKEN  ... チャネルアクセストークン (Long-lived)
#   LINE_PUSH_TO               ... 送信先 LINE ユーザーID (or グループID)
#
# トークン未設定なら静かに no-op (例外を投げない)。
class LineNotifier
  PUSH_URL = "https://api.line.me/v2/bot/message/push".freeze

  def self.push(text)
    new.push(text)
  end

  def push(text)
    token = ENV["LINE_CHANNEL_ACCESS_TOKEN"].to_s
    to = ENV["LINE_PUSH_TO"].to_s
    return false if token.blank? || to.blank?

    uri = URI.parse(PUSH_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"]  = "application/json"
    req["Authorization"] = "Bearer #{token}"
    req.body = {
      to: to,
      messages: [ { type: "text", text: text.to_s[0, 4900] } ]
    }.to_json

    res = http.request(req)
    Rails.logger.info("[LineNotifier] status=#{res.code} body=#{res.body}") unless res.code.start_with?("2")
    res.code.start_with?("2")
  rescue => e
    Rails.logger.warn("[LineNotifier] error: #{e.class}: #{e.message}")
    false
  end
end
