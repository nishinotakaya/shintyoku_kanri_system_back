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
      head_sha: pr.dig("head", "sha"), # ファイル単位レビューコメント投稿に必要な commit_id
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

  # 自分宛ての通知(メンション・レビュー依頼・参加スレッドの新着コメント等)を取得。
  # reason: mention / review_requested / comment / assign など。
  # mention/comment はそのコメント本文も取得して一緒に返す。
  def notifications(limit: 30)
    items = Array(get("/notifications", { "all" => "false", "per_page" => 50 }))
    items.first(limit).map do |item|
      subject = item["subject"] || {}
      repo_full_name = item.dig("repository", "full_name")
      number = subject["url"].to_s[%r{/(?:pulls|issues)/(\d+)\z}, 1]&.to_i
      comment = latest_comment_for(item, subject)
      {
        id: item["id"],
        reason: item["reason"],
        repo_full_name: repo_full_name,
        title: subject["title"],
        type: subject["type"], # PullRequest / Issue
        number: number,
        updated_at: item["updated_at"],
        html_url: comment&.dig(:html_url) || web_url_for(repo_full_name, subject["type"], number),
        comment: comment
      }
    end
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

  # 変更ファイル単位のレビューコメントを PR に投稿する(公開・即時)。
  # subject_type: "file" で行指定なしのファイル全体コメントにする。commit_id は PR の head_sha。
  def create_review_comment(full_name, number, commit_id, path, body)
    full_name = validated_full_name(full_name)
    number = validated_number(number)
    data = post("/repos/#{full_name}/pulls/#{number}/comments", {
      body: body, commit_id: commit_id, path: path, subject_type: "file"
    })
    {
      id: data["id"],
      user: data.dig("user", "login"),
      path: data["path"],
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

  # 通知に紐づく最新コメント(あれば)を取得して整形。無ければ nil。
  def latest_comment_for(item, subject)
    url = subject["latest_comment_url"].to_s
    return nil unless url.start_with?("https://api.github.com/") # 想定外URLは叩かない
    return nil unless %w[mention comment review_requested team_mention author].include?(item["reason"])

    data = request(method: :get, path: url.sub("https://api.github.com", ""))
    return nil if data.blank?
    {
      user: data.dig("user", "login"),
      body: data["body"].to_s.slice(0, 2000),
      html_url: data["html_url"]
    }
  rescue StandardError
    nil # コメント取得失敗は通知一覧自体を止めない
  end

  # 通知アイテムのブラウザ表示URL(コメントが無いとき用)。
  def web_url_for(repo_full_name, type, number)
    return nil if repo_full_name.blank? || number.blank?
    kind = type == "Issue" ? "issues" : "pull"
    "https://github.com/#{repo_full_name}/#{kind}/#{number}"
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
