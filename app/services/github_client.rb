require "net/http"
require "json"
require "uri"

# GitHub REST API v3 クライアント（Personal Access Token 認証）
class GithubClient
  def initialize(setting)
    @token = setting&.personal_access_token
    raise "GitHub Personal Access Token が未設定です" unless @token.present?
  end

  # 接続テスト・ヘッダー表示用に自分のユーザー情報を取得
  def me
    data = get("/user")
    { login: data["login"], name: data["name"], avatar_url: data["avatar_url"] }
  end

  # 自分がアクセス可能なリポジトリ一覧（owner/collaborator/organization member）
  def repositories
    data = get("/user/repos", { "per_page" => 100, "sort" => "updated", "affiliation" => "owner,collaborator,organization_member" })
    Array(data).map do |repo|
      {
        full_name: repo["full_name"],
        name: repo["name"],
        owner: repo.dig("owner", "login"),
        private: repo["private"],
        html_url: repo["html_url"],
        description: repo["description"],
        updated_at: repo["updated_at"],
        open_issues_count: repo["open_issues_count"]
      }
    end
  end

  # PR 一覧
  def pull_requests(full_name, state: "all")
    full_name = validated_full_name(full_name)
    data = get("/repos/#{full_name}/pulls", { "state" => state, "per_page" => 50, "sort" => "updated", "direction" => "desc" })
    Array(data).map do |pr|
      {
        number: pr["number"],
        title: pr["title"],
        state: pr["state"],
        user: pr.dig("user", "login"),
        html_url: pr["html_url"],
        created_at: pr["created_at"],
        updated_at: pr["updated_at"],
        draft: pr["draft"],
        merged_at: pr["merged_at"],
        comments: pr["comments"],
        body: pr["body"].to_s.slice(0, 200)
      }
    end
  end

  # PR 詳細: 本体・会話コメント・変更ファイルをまとめて返す
  def pull_request_detail(full_name, number)
    full_name = validated_full_name(full_name)
    number = validated_number(number)
    pr = get("/repos/#{full_name}/pulls/#{number}")
    comments = get("/repos/#{full_name}/issues/#{number}/comments")
    files = get("/repos/#{full_name}/pulls/#{number}/files")

    {
      number: pr["number"],
      title: pr["title"],
      state: pr["state"],
      body: pr["body"],
      user: pr.dig("user", "login"),
      html_url: pr["html_url"],
      merged: pr["merged"],
      comments: Array(comments).map { |c|
        {
          id: c["id"],
          user: c.dig("user", "login"),
          body: c["body"],
          created_at: c["created_at"],
          html_url: c["html_url"]
        }
      },
      files: Array(files).map { |f|
        {
          filename: f["filename"],
          status: f["status"],
          additions: f["additions"],
          deletions: f["deletions"],
          patch: f["patch"].to_s.slice(0, 4000)
        }
      }
    }
  end

  # PR(issue) へのコメント投稿
  def create_comment(full_name, number, body)
    full_name = validated_full_name(full_name)
    number = validated_number(number)
    data = post("/repos/#{full_name}/issues/#{number}/comments", { body: body })
    {
      id: data["id"],
      user: data.dig("user", "login"),
      body: data["body"],
      created_at: data["created_at"],
      html_url: data["html_url"]
    }
  end

  private

  # full_name(owner/repo) と number は URL に差し込むので、想定書式だけ許可して
  # api.github.com 内の別パスへ逸脱させない(GitHub API 相手なので致命ではないが防御的に)。
  def validated_full_name(full_name)
    value = full_name.to_s.strip
    owner, repo, extra = value.split("/", 3)
    valid = extra.nil? &&
            owner.to_s.match?(/\A[\w-]+\z/) &&      # GitHub の owner(ユーザー/組織)は英数字とハイフン
            repo.to_s.match?(/\A[\w.-]+\z/) &&       # repo はドットも可
            !value.include?("..")                    # ".." による親ディレクトリ遡上を禁止
    raise "不正なリポジトリ指定です: #{value}" unless valid
    value
  end

  def validated_number(number)
    Integer(number.to_s.strip)
  rescue ArgumentError, TypeError
    raise "不正なPR番号です: #{number}"
  end

  def get(path, params = {})
    request(method: :get, path: build_path(path, params))
  end

  def post(path, body)
    request(method: :post, path: path, body: body)
  end

  def build_path(path, params)
    return path if params.blank?
    query = URI.encode_www_form(params)
    "#{path}?#{query}"
  end

  # GitHub REST API への HTTP 呼び出しを単一メソッドに統一。
  def request(method:, path:, body: nil)
    uri = URI("https://api.github.com#{path}")

    http = Net::HTTP.new(uri.host, uri.port).tap do |h|
      h.use_ssl = true
      h.open_timeout = 10
      h.read_timeout = 30
    end

    klass = REQUEST_CLASSES.fetch(method) { raise ArgumentError, "Unsupported method: #{method}" }
    req = klass.new(uri.request_uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["User-Agent"] = "kintai-app"
    if body
      req["Content-Type"] = "application/json"
      req.body = body.to_json
    end

    res = http.request(req)
    unless res.code.start_with?("2")
      raise "GitHub API #{method.to_s.upcase} error (#{res.code}): #{res.body.to_s[0..200]}"
    end
    JSON.parse(res.body)
  rescue JSON::ParserError
    {}
  end

  REQUEST_CLASSES = {
    get:  Net::HTTP::Get,
    post: Net::HTTP::Post
  }.freeze
end
