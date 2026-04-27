require "net/http"
require "json"
require "uri"

# Backlog REST API v2 クライアント（API キー認証）
class BacklogClient
  def initialize(setting)
    @base_url = setting.backlog_url.chomp("/")
    @api_key = setting.api_key
    @user_id = setting.user_backlog_id
    @assignee_ids = JSON.parse(setting.assignee_ids || "[]") rescue [ setting.user_backlog_id ]
    @assignee_ids = [ @user_id ] if @assignee_ids.empty?
    raise "Backlog API キーが未設定です" unless @api_key.present?
  end

  # 接続テスト: 自分のユーザー情報を取得
  def test_connection
    data = get("/api/v2/users/myself")
    { success: true, name: data["name"], user_id: data["id"] }
  rescue => e
    { success: false, error: e.message }
  end

  # 名前から Backlog ユーザー ID を引く。
  # 1) /users/myself（誰でも可）→ API キー所有者本人なら即返す
  # 2) /users（admin 限定）→ 取れたら全社ユーザーから探す
  # 3) /projects → 各 project の /projects/:id/users（メンバなら誰でも可）から探す
  def find_user_id_by_name(name)
    target = norm(name)
    me = get("/api/v2/users/myself")
    return me["id"] if norm(me["name"]) == target

    if (users = (get("/api/v2/users") rescue nil))
      hit = users.find { |u| norm(u["name"]) == target }
      return hit["id"] if hit
    end

    projects = get("/api/v2/projects") rescue []
    projects.each do |proj|
      members = get("/api/v2/projects/#{proj['id']}/users") rescue []
      hit = members.find { |u| norm(u["name"]) == target }
      return hit["id"] if hit
    end
    nil
  end

  private def norm(s)
    s.to_s.gsub(/[\s　]+/, "")
  end
  public

  # 任意の assignee_ids で fetch_issues を実行
  def fetch_issues_for(assignee_ids, project_id: nil, status_ids: [ 1, 2, 3, 4 ])
    @assignee_ids = Array(assignee_ids)
    fetch_issues(project_id: project_id, status_ids: status_ids)
  end

  # 指定 issue のコメント一覧（古い順）
  def fetch_comments(issue_key)
    get("/api/v2/issues/#{issue_key}/comments", { "order" => "asc", "count" => 100 })
  end

  # 自分にアサインされたイシューを取得（全ステータス）
  def fetch_issues(project_id: nil, status_ids: [ 1, 2, 3, 4 ])
    all_issues = []
    @assignee_ids.each do |aid|
      params = {
        "assigneeId[]" => aid,
        "statusId[]" => status_ids,
        "count" => 100,
        "sort" => "updated",
        "order" => "desc"
      }
      params["projectId[]"] = project_id if project_id
      issues = get("/api/v2/issues", params)
      all_issues.concat(issues)
    end
    # issue_key で重複排除
    all_issues.uniq { |i| i["issueKey"] }
  end

  private

  def get(path, params = {})
    uri = URI("#{@base_url}#{path}")
    query = params.flat_map { |k, v|
      Array(v).map { |val| "#{k}=#{CGI.escape(val.to_s)}" }
    }
    query << "apiKey=#{@api_key}"
    uri.query = query.join("&")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    res = http.get(uri.request_uri)
    raise "Backlog API error (#{res.code}): #{res.body[0..200]}" unless res.code == "200"
    JSON.parse(res.body)
  end
end
