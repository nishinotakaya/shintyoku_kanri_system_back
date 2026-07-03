require "net/http"
require "json"
require "date"

# スキルシートの案件(SkillSheetProject)を、外部求人プロフィールの職務経歴へ連携する。
# - Wantedly: GraphQL createWorkExperience
# - 副業クラウド(AnotherWorks): REST POST /v3/talent/talent/resumes
# 会社名(正規化)＋保存済み連携IDで重複を防ぐ(upsert)。トークンは sheet.user に保持。
class JobProfileSyncer
  WANTEDLY_GRAPHQL = "https://graphql-gateway.wantedly.com/graphql"
  AW_BASE          = "https://fc-core-api.aw-anotherworks.com"
  # TODO: 将来は user 設定に。現状は西野さんのアカウント固定。
  WANTEDLY_SLUG    = "taka_nishino_a"
  WANTEDLY_USER_ID = "166868454"

  # platforms: [:wantedly, :anotherworks] のサブセット / only_position: 指定すると1案件のみ
  def initialize(skill_sheet:, platforms: %i[wantedly anotherworks], only_position: nil)
    @sheet = skill_sheet
    @user = skill_sheet.user
    @platforms = Array(platforms).map(&:to_sym)
    @only_position = only_position
  end

  def call
    projects = @sheet.projects.order(:position).to_a
    projects = projects.select { |p| p.position == @only_position } if @only_position
    result = {}
    if @platforms.include?(:wantedly)
      result[:wantedly] = @user.wantedly_token.present? ? sync_wantedly(projects) : [ { status: "no_token" } ]
    end
    if @platforms.include?(:anotherworks)
      result[:anotherworks] = @user.anotherworks_token.present? ? sync_anotherworks(projects) : [ { status: "no_token" } ]
    end
    result
  end

  private

  def norm(value) = value.to_s.gsub(/業務委託|■|[()（）\s　]/, "").strip
  def ym(value)
    m = value.to_s.match(/(\d{4})\D+(\d{1,2})/)
    m ? [ m[1].to_i, m[2].to_i ] : nil
  end
  def ymd(value, last = false)
    y, mo = ym(value)
    y ? format("%04d-%02d-%02d", y, mo, last ? Date.new(y, mo, -1).day : 1) : nil
  end

  # ── Wantedly ──
  def wantedly_request(query, variables)
    uri = URI(WANTEDLY_GRAPHQL)
    http = Net::HTTP.new(uri.host, 443).tap { _1.use_ssl = true }
    req = Net::HTTP::Post.new(uri.path)
    req["authorization"] = "Bearer #{@user.wantedly_token}"
    req["content-type"]  = "application/json"
    req["origin"]        = "https://www.wantedly.com"
    req.body = { query: query, variables: variables }.to_json
    JSON.parse(http.request(req).body.to_s.force_encoding("UTF-8"))
  rescue => e
    { "error" => e.message }
  end

  # 自己PR(self_pr) → Wantedly の introduction(自己紹介) を更新
  def update_wantedly_introduction
    return nil if @sheet.self_pr.to_s.strip.empty?
    mutation = "mutation($userId:String,$introduction:String!){partialUpdateProfile(input:{userId:$userId,introduction:$introduction}){profile{userId introduction}}}"
    data = wantedly_request(mutation, { userId: WANTEDLY_USER_ID, introduction: @sheet.self_pr.to_s })
    ok = data.dig("data", "partialUpdateProfile", "profile", "introduction")
    { title: "自己PR(introduction)", status: ok ? "updated" : "error: #{data.to_json[0, 120]}" }
  end

  def sync_wantedly(projects)
    rows = []
    # 1案件のみ(個別連携)のときは自己PRは触らない。全件(一括)のときに自己PRも反映。
    if @only_position.nil?
      intro = update_wantedly_introduction
      rows << intro if intro
    end
    existing = wantedly_request(
      "query($slug:String!){userBySlug(slug:$slug){civicProfile{workExperiences{uuid companyName}}}}",
      { slug: WANTEDLY_SLUG }
    ).dig("data", "userBySlug", "civicProfile", "workExperiences") || []
    uuid_by_name = {}
    existing.each { |x| uuid_by_name[norm(x["companyName"])] = x["uuid"] }

    create_mut = "mutation($input: CreateWorkExperienceInput!){createWorkExperience(input:$input){workExperience{uuid}}}"
    update_mut = "mutation($input: PartialUpdateWorkExperienceInput!){partialUpdateWorkExperience(input:$input){workExperience{uuid}}}"
    created = projects.map do |project|
      start_year, start_month = ym(project.period_from)
      next { title: project.title, status: "skip(期間不明)" } unless start_year
      incumbent = project.period_to.to_s.include?("現在")
      fields = {
        companyName: project.title, position: "Webエンジニア/プログラマー",
        occupationTypeV2Object: { name: "JP__WEB_ENGINEER" }, employmentType: "FULL_TIME",
        description: project.description.to_s, descriptionForHr: project.role_scale.to_s,
        duration: { start: { year: start_year, month: start_month } }, privacyStatus: "EVERYONE"
      }
      end_year, end_month = ym(project.period_to)
      fields[:duration][:end] = { year: end_year, month: end_month } if !incumbent && end_year

      target_uuid = project.wantedly_work_experience_uuid.presence || uuid_by_name[norm(project.title)]
      if target_uuid
        # 既存は partialUpdateWorkExperience で上書き更新
        data = wantedly_request(update_mut, { input: fields.merge(uuid: target_uuid) })
        ok = data.dig("data", "partialUpdateWorkExperience", "workExperience", "uuid")
        project.update_column(:wantedly_work_experience_uuid, target_uuid) if project.wantedly_work_experience_uuid.blank?
        { title: project.title, status: ok ? "updated" : "error(update): #{data.to_json[0, 120]}" }
      else
        data = wantedly_request(create_mut, { input: fields.merge(userId: WANTEDLY_USER_ID, autocompletionResultId: nil) })
        uuid = data.dig("data", "createWorkExperience", "workExperience", "uuid")
        project.update_column(:wantedly_work_experience_uuid, uuid) if uuid
        { title: project.title, status: uuid ? "created" : "error: #{data.to_json[0, 120]}" }
      end
    end
    rows + created
  end

  # ── 副業クラウド (AnotherWorks) ──
  def aw_get(path)
    uri = URI("#{AW_BASE}/#{path}")
    http = Net::HTTP.new(uri.host, 443).tap { _1.use_ssl = true }
    req = Net::HTTP::Get.new(uri.request_uri)
    req["auth-type"] = "firebase"
    req["authorization"] = "Bearer #{@user.anotherworks_token}"
    req["origin"] = "https://talent.aw-anotherworks.com"
    http.request(req).body.to_s.force_encoding("UTF-8")
  end

  def aw_post_resume(body)
    uri = URI("#{AW_BASE}/v3/talent/talent/resumes")
    http = Net::HTTP.new(uri.host, 443).tap { _1.use_ssl = true }
    req = Net::HTTP::Post.new(uri.path)
    req["auth-type"] = "firebase"
    req["authorization"] = "Bearer #{@user.anotherworks_token}"
    req["content-type"] = "application/json; charset=UTF-8"
    req["origin"] = "https://talent.aw-anotherworks.com"
    req.body = body.to_json
    res = http.request(req)
    [ res.code, res.body.to_s.force_encoding("UTF-8") ]
  end

  def aw_patch_resume(body)
    uri = URI("#{AW_BASE}/v3/talent/talent/resumes")
    http = Net::HTTP.new(uri.host, 443).tap { _1.use_ssl = true }
    req = Net::HTTP::Patch.new(uri.path)
    req["auth-type"] = "firebase"
    req["authorization"] = "Bearer #{@user.anotherworks_token}"
    req["content-type"] = "application/json; charset=UTF-8"
    req["origin"] = "https://talent.aw-anotherworks.com"
    req.body = body.to_json
    res = http.request(req)
    [ res.code, res.body.to_s.force_encoding("UTF-8") ]
  end

  def aw_existing_resumes
    JSON.parse(aw_get("v2/talent/talents")).dig("data", "talent", "resumes") || []
  rescue
    []
  end

  # 既存は PATCH で更新、無ければ POST で作成 (upsert)。会社名(正規化)で既存IDを引く。
  def sync_anotherworks(projects)
    id_by_name = {}
    aw_existing_resumes.each { |r| id_by_name[norm(r["companyName"])] = r["id"] }

    out = projects.map do |project|
      incumbent = project.period_to.to_s.include?("現在")
      fields = {
        companyName: project.title, title: "エンジニア", detailText: project.description.to_s,
        isIncumbent: incumbent, isPublic: true, startDate: ymd(project.period_from)
      }
      fields[:endDate] = ymd(project.period_to, true) unless incumbent
      target_id = project.anotherworks_resume_id.presence || id_by_name[norm(project.title)]
      if target_id
        code, res = aw_patch_resume(fields.compact.merge(id: target_id))
        project.update_column(:anotherworks_resume_id, target_id) if project.anotherworks_resume_id.blank?
        { title: project.title, status: (%w[200 204].include?(code) ? "updated" : "error: #{code} #{res[0, 80]}") }
      else
        code, res = aw_post_resume(fields.compact)
        { title: project.title, status: (code == "201" ? "created" : "error: #{code} #{res[0, 80]}") }
      end
    end
    # POST 分の id を会社名で紐付け（次回 upsert 用）
    after = {}
    aw_existing_resumes.each { |r| after[norm(r["companyName"])] = r["id"] }
    projects.each do |project|
      id = after[norm(project.title)]
      project.update_column(:anotherworks_resume_id, id) if id && project.anotherworks_resume_id.blank?
    end
    out
  end
end
