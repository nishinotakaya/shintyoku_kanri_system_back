require "net/http"
require "json"
require "uri"

# Trello REST API (v1) クライアント。ボードのリスト/カードを取得する。
class TrelloClient
  BASE_URL = "https://api.trello.com/1"

  class AuthError < StandardError; end
  class ApiError  < StandardError; end

  def initialize(api_key: ENV["TRELLO_API_KEY"], api_token: ENV["TRELLO_API_TOKEN"], board_id: ENV["TRELLO_BOARD_ID"])
    if api_key.to_s.strip.empty? || api_token.to_s.strip.empty? || board_id.to_s.strip.empty?
      raise AuthError, "Trello API キー/トークンを確認してください"
    end
    @api_key = api_key
    @api_token = api_token
    @board_id = board_id
  end

  # ボード内のリスト一覧 (id -> name の対応付けに使う)
  def fetch_lists
    get("/boards/#{@board_id}/lists")
  end

  # ボード内のカード一覧 (メンバー・所属リストなどを含む)
  def fetch_cards
    get(
      "/boards/#{@board_id}/cards",
      members: "true",
      fields: "name,desc,due,start,idList,idBoard,shortUrl,pos,closed",
      member_fields: "fullName"
    )
  end

  # ボード名を取得する (board_name 保存用)
  def fetch_board
    get("/boards/#{@board_id}", fields: "name")
  end

  private

  def get(path, extra_params = {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(extra_params.merge(key: @api_key, token: @api_token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)

    begin
      response = http.request(request)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
      raise ApiError, "Trello API に接続できませんでした: #{e.class}"
    end

    case response.code
    when "200"
      JSON.parse(response.body)
    when "401", "403"
      raise AuthError, "Trello API キー/トークンを確認してください"
    else
      raise ApiError, "Trello API エラー HTTP #{response.code}: #{response.body[0, 300]}"
    end
  end
end
