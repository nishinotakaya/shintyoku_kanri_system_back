class SkillSheet < ApplicationRecord
  belongs_to :user
  has_many :projects, -> { order(:position) }, class_name: "SkillSheetProject", dependent: :destroy, inverse_of: :skill_sheet
  has_many :comments, -> { order(:created_at) }, class_name: "SkillSheetComment", dependent: :destroy, inverse_of: :skill_sheet
  has_many :techs, -> { order(last_used_rank: :desc, months_used: :desc) }, class_name: "SkillSheetTech", dependent: :destroy, inverse_of: :skill_sheet
  has_many :review_items, -> { order(:position) }, class_name: "SkillSheetReviewItem", dependent: :destroy, inverse_of: :skill_sheet
  has_many :evaluations, -> { order(:label) }, class_name: "SkillSheetEvaluation", dependent: :destroy, inverse_of: :skill_sheet

  accepts_nested_attributes_for :projects, allow_destroy: true

  # spreadsheet_url を「書き込み先の唯一の正」とし、URL が変わったら spreadsheet_id / gid を再導出する。
  # これが無いと URL を編集しても古い import 時の spreadsheet_id が残り、export が別シートに書き込んでしまう。
  before_save :sync_spreadsheet_reference, if: :will_save_change_to_spreadsheet_url?

  def sync_spreadsheet_reference
    return if spreadsheet_url.blank?
    if (matched_id = spreadsheet_url[%r{/spreadsheets/d/([a-zA-Z0-9_-]+)}, 1])
      self.spreadsheet_id = matched_id
    end
    if (matched_gid = spreadsheet_url[/[?#&]gid=(\d+)/, 1])
      self.gid = matched_gid
    end
  end

  # AI 添削結果 (JSON) / Before スナップショット (JSON)。SQLite なので text + serialize。
  serialize :review_result, coder: JSON
  serialize :before_snapshot, coder: JSON

  # 現在の構造化内容を Before (添削前) スナップショットとして取り込む。
  def capture_before_snapshot!
    update!(before_snapshot: structured_content)
  end

  # 編集可能な構造化内容 (Before/After 比較や書き戻しに使う)
  def structured_content
    HEADER_ATTRS.index_with { |a| public_send(a) }.merge("projects" => projects.map(&:as_payload))
  end

  HEADER_ATTRS = %w[
    engineer_name age gender address start_date nearest_station
    specialties skills duties self_pr
  ].freeze

  PROJECT_ATTRS = %w[
    period_from period_to title description role_scale languages db server_os tools phases
  ].freeze

  # アプリ内編集の保存(update)用。フォームの全案件で置き換える（source は各案件の値を保持・既定 import）。
  def apply_structured!(data)
    data = data.to_h.with_indifferent_access
    attrs = HEADER_ATTRS.each_with_object({}) do |k, h|
      h[k] = data[k] if data.key?(k)
    end
    transaction do
      update!(attrs)
      # 既存で source='backlog' だった案件タイトルを記録 → フォームが古い source='import' を送ってきても backlog を維持する
      backlog_titles = projects.where(source: "backlog").pluck(:title).map { |t| t.to_s.strip }.reject(&:empty?)
      projects.destroy_all
      Array(data[:projects]).each_with_index do |p, idx|
        ph = p.to_h.with_indifferent_access
        src = ph[:source].presence
        src = "backlog" if backlog_titles.include?(ph[:title].to_s.strip) && (src.nil? || src == "import")
        create_project_from!(ph.merge("source" => src), idx)
      end
    end
    reload
  end

  # スプレッドシート取り込み(import)用の UPSERT。
  # source='backlog'(Backlog実績から生成した案件)は消さず保持し、source='import' のみ入れ替える。
  def apply_import!(data)
    data = data.to_h.with_indifferent_access
    attrs = HEADER_ATTRS.each_with_object({}) { |k, h| h[k] = data[k] if data.key?(k) }
    transaction do
      update!(attrs)
      kept = projects.where(source: "backlog").order(:position).to_a
      projects.where.not(source: "backlog").destroy_all
      imported = Array(data[:projects]).each_with_index.map { |p, idx| create_project_from!(p, idx, source: "import") }
      # Backlog分は取り込み案件の後ろに並べ直す（順序を安定させる）
      kept.each_with_index { |proj, i| proj.update_column(:position, imported.size + i) }
    end
    reload
  end

  def create_project_from!(p, idx, source: nil)
    p = p.to_h.with_indifferent_access
    projects.create!(
      position: idx,
      period_from: p[:period_from], period_to: p[:period_to],
      title: p[:title], description: p[:description], role_scale: p[:role_scale],
      languages: p[:languages], db: p[:db], server_os: p[:server_os],
      tools: p[:tools], phases: (p[:phases] || {}).to_h,
      source: (source || p[:source].presence || "import")
    )
  end

  def as_payload
    {
      id: id,
      user_id: user_id,
      spreadsheet_url: spreadsheet_url,
      spreadsheet_id: spreadsheet_id,
      gid: gid,
      engineer_name: engineer_name,
      age: age,
      gender: gender,
      address: address,
      start_date: start_date,
      nearest_station: nearest_station,
      specialties: specialties,
      skills: skills,
      duties: duties,
      self_pr: self_pr,
      youtube_self_pr: youtube_self_pr,
      review_result: review_result,
      before_snapshot: before_snapshot,
      reviewed_at: reviewed_at&.iso8601,
      synced_at: synced_at&.iso8601,
      projects: projects.map(&:as_payload),
      comments: comments.map(&:as_payload),
      techs: techs.map(&:as_payload),
      review_items: review_items.map(&:as_payload),
      evaluations: evaluations.map(&:as_payload)
    }
  end
end
