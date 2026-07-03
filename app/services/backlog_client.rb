require "net/http"
require "json"
require "uri"
require "securerandom"

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

  # 課題の changeLog から「状態 → 完了」になった日付(=完了日)を返す。
  # 最新側(order=desc)から探し、最初に見つかった完了化のコメント作成日を採用する。無ければ nil。
  def fetch_issue_completion_date(issue_key)
    comments = get("/api/v2/issues/#{issue_key}/comments", { "order" => "desc", "count" => 100 })
    Array(comments).each do |comment|
      Array(comment["changeLog"]).each do |change|
        next unless change["field"] == "status" && change["newValue"].to_s == "完了"
        return (Date.parse(comment["created"].to_s) rescue nil)
      end
    end
    nil
  rescue
    nil
  end

  # 指定ユーザーの活動履歴（課題追加/更新/コメント等）を maxId で遡って全件取得する。
  #   activity_type_ids: 1=課題追加 2=課題更新 3=課題コメント 14=課題一括更新
  def fetch_user_activities(user_backlog_id, activity_type_ids: [ 1, 2, 3, 14 ], max_pages: 20)
    all = []
    max_id = nil
    max_pages.times do
      params = { "activityTypeId[]" => activity_type_ids, "count" => 100 }
      params["maxId"] = max_id if max_id
      batch = get("/api/v2/users/#{user_backlog_id}/activities", params)
      break if batch.blank?
      all.concat(batch)
      break if batch.size < 100
      max_id = batch.last["id"].to_i - 1
    end
    all
  end

  # コメント新規追加 (POST)
  def add_comment(issue_key, content:, notified_user_ids: [], attachment_ids: [])
    body = { "content" => content }
    notified_user_ids.each_with_index do |uid, i|
      body["notifiedUserId[#{i}]"] = uid
    end
    attachment_ids.each_with_index do |aid, i|
      body["attachmentId[#{i}]"] = aid
    end
    post_form("/api/v2/issues/#{issue_key}/comments", body)
  end

  # 添付ファイル登録 (POST /space/attachment)。multipart で送る。
  # 戻り値: { "id" => ..., "name" => ..., "size" => ... }
  def upload_attachment(filename:, content_type:, content:)
    boundary = "----RubyMultipart#{SecureRandom.hex(8)}"
    safe_filename = filename.to_s.gsub(/[\r\n"]/, "_")
    body = +""
    body << "--#{boundary}\r\n"
    body << %(Content-Disposition: form-data; name="file"; filename="#{safe_filename}"\r\n)
    body << "Content-Type: #{content_type.presence || 'application/octet-stream'}\r\n\r\n"
    body << content
    body << "\r\n--#{boundary}--\r\n"

    uri = URI("#{@base_url}/api/v2/space/attachment?apiKey=#{@api_key}")
    http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = (uri.scheme == "https") }
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    req.body = body.dup.force_encoding(Encoding::ASCII_8BIT)
    res = http.request(req)
    raise "Backlog attachment upload error (#{res.code}): #{res.body[0..200]}" unless res.code.start_with?("2")
    JSON.parse(res.body)
  end

  # コメント編集 (PATCH)
  def update_comment(issue_key, comment_id, content:)
    patch_form("/api/v2/issues/#{issue_key}/comments/#{comment_id}", { "content" => content })
  end

  # コメント削除 (DELETE)
  def delete_comment(issue_key, comment_id)
    delete("/api/v2/issues/#{issue_key}/comments/#{comment_id}")
  end

  # メンション候補用のユーザー一覧。
  # 1) /users/myself (自分)
  # 2) /users (admin 限定 — 失敗してもスキップ)
  # 3) /projects/:id/users (各 project の member — admin 不要)
  # の和集合を返す。
  def fetch_users
    all = {}
    me = (get("/api/v2/users/myself") rescue nil)
    all[me["id"]] = me if me

    (get("/api/v2/users") rescue []).each { |u| all[u["id"]] ||= u }

    (get("/api/v2/projects") rescue []).each do |proj|
      members = (get("/api/v2/projects/#{proj['id']}/users") rescue [])
      members.each { |u| all[u["id"]] ||= u }
    end

    all.values
  rescue
    []
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

  # Backlog REST API への HTTP 呼び出しを単一メソッドに統一。
  # method  :get / :post / :patch / :delete
  # path    "/api/v2/..."
  # params  GET クエリパラメータ (Array 値で同名繰り返し可)
  # body    POST/PATCH 用フォームデータ (Hash)
  def request(method:, path:, params: {}, body: nil)
    klass = REQUEST_CLASSES.fetch(method) { raise ArgumentError, "Unsupported method: #{method}" }
    uri = build_uri(path, params)

    http = Net::HTTP.new(uri.host, uri.port).tap do |h|
      h.use_ssl = (uri.scheme == "https")
      h.open_timeout = 10
      h.read_timeout = 30
    end

    req = klass.new(uri.request_uri)
    if body
      req["content-type"] = "application/x-www-form-urlencoded"
      req.body = URI.encode_www_form(body)
    end

    res = http.request(req)
    unless res.code.start_with?("2")
      raise "Backlog API #{method.to_s.upcase} error (#{res.code}): #{res.body.to_s[0..200]}"
    end
    JSON.parse(res.body)
  rescue JSON::ParserError
    {}
  end

  REQUEST_CLASSES = {
    get:    Net::HTTP::Get,
    post:   Net::HTTP::Post,
    patch:  Net::HTTP::Patch,
    delete: Net::HTTP::Delete
  }.freeze

  def build_uri(path, params)
    uri = URI("#{@base_url}#{path}")
    pairs = params.flat_map { |k, v| Array(v).map { |val| "#{k}=#{CGI.escape(val.to_s)}" } }
    pairs << "apiKey=#{@api_key}"
    uri.query = pairs.join("&")
    uri
  end

  def get(path, params = {})  = request(method: :get, path: path, params: params)
  def post_form(path, body)   = request(method: :post, path: path, body: body)
  def patch_form(path, body)  = request(method: :patch, path: path, body: body)
  def delete(path)            = request(method: :delete, path: path)
end
