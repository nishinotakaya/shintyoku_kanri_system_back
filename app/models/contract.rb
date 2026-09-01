# 業務委託契約書。甲(発行者=user)が作成し、乙(相手方、自由入力)にリンクを発行して電子署名を受ける。
class Contract < ApplicationRecord
  belongs_to :user
  has_many :contract_events, dependent: :destroy

  # app/models/contract/default_articles.rb (Zeitwerk規約で Contract::DefaultArticles) から取り込む。
  DEFAULT_ARTICLES = DefaultArticles::LIST

  # HAUKUR運送の紙の原本どおりの条文(全29条・6ページ)。改ページ位置は page_break_before で持つ。
  TRANSPORT_ARTICLES = TransportArticles::LIST

  # 契約書作成時に選べる条文テンプレート。キーはフロントから渡ってくる template パラメータ。
  ARTICLE_TEMPLATES = {
    "standard" => DEFAULT_ARTICLES,
    "transport" => TRANSPORT_ARTICLES
  }.freeze

  def self.articles_for_template(template_key)
    ARTICLE_TEMPLATES.fetch(template_key.to_s, DEFAULT_ARTICLES)
  end

  STATUSES = %w[draft sent signed void].freeze

  # 本文とみなす属性。signed/void になった後は変更できない(freeze_body_when_signed_or_void)。
  BODY_ATTRIBUTES = %w[
    title party_a_name party_a_address party_a_representative
    party_b_name party_b_address party_b_representative
    contract_date start_on end_on articles special_terms
  ].freeze

  serialize :articles, coder: JSON

  validates :title, presence: true
  validates :party_a_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_update :freeze_body_when_signed_or_void

  class NotSignable < StandardError; end

  # draft/sent の間は本文を編集できる。signed/void になったら凍結。
  def editable?
    status.in?(%w[draft sent])
  end

  # 期限内に送付済みで、まだ誰にも署名されていないか。
  def signable?
    status == "sent" && share_expires_at.present? && share_expires_at.future?
  end

  # 署名リンクを発行(再発行)する。生トークンはこの戻り値でしか取得できない(以後は digest しか保持しない)。
  def issue!(actor:)
    raw_token = SecureRandom.urlsafe_base64(32)
    update!(
      share_token_digest: Digest::SHA256.hexdigest(raw_token),
      status: "sent",
      sent_at: Time.current,
      share_expires_at: 30.days.from_now
    )
    record_event("issued", actor: actor)
    raw_token
  end

  def self.find_by_share_token(raw_token)
    return nil if raw_token.blank?
    find_by(share_token_digest: Digest::SHA256.hexdigest(raw_token))
  end

  # 乙による電子署名。二重署名防止のため with_lock 内で signable? を再確認する。
  def sign!(signer_name:, signature_image:, ip: nil, user_agent: nil)
    begin
      SignatureImage.validate!(signature_image)
    rescue SignatureImage::InvalidSignatureImage => e
      errors.add(:base, e.message)
      raise ActiveRecord::RecordInvalid.new(self)
    end

    with_lock do
      raise NotSignable, "この契約書は署名できません（期限切れ・既に署名済み・無効）" unless signable?

      self.content_sha256 = Digest::SHA256.hexdigest(canonical_content_json)
      self.signed_at = Time.current
      self.signer_name = signer_name
      self.signature_image = signature_image
      self.signer_ip = ip
      self.signer_user_agent = user_agent
      self.status = "signed"
      self.signed_pdf = ContractPdfRenderer.new(self).render_bytes
      save!
    end

    record_event("signed", actor: "party_b", ip: ip, user_agent: user_agent)
    self
  end

  def party_a_hash
    { name: party_a_name.to_s, address: party_a_address.to_s, representative: party_a_representative.to_s }
  end

  def party_b_hash
    { name: party_b_name.to_s, address: party_b_address.to_s, representative: party_b_representative.to_s }
  end

  # 複製して新規 draft を作る。日付・署名系は引き継がない。
  def duplicate_for(user)
    self.class.create!(
      user: user,
      title: title,
      party_a_name: party_a_name,
      party_a_address: party_a_address,
      party_a_representative: party_a_representative,
      party_b_name: party_b_name,
      party_b_address: party_b_address,
      party_b_representative: party_b_representative,
      articles: articles,
      special_terms: special_terms,
      status: "draft"
    )
  end

  def record_event(event, actor:, ip: nil, user_agent: nil, detail: nil)
    contract_events.create!(event: event.to_s, actor: actor, ip: ip, user_agent: user_agent, detail: detail)
  end

  private

  # 署名対象の内容を、キー順序を固定した JSON にして SHA-256 のハッシュ元にする。
  def canonical_content_json
    normalized_articles = Array(articles).map do |article|
      indifferent = article.is_a?(Hash) ? article.with_indifferent_access : {}
      { heading: indifferent[:heading].to_s, body: indifferent[:body].to_s }
    end

    {
      title: title.to_s,
      party_a: party_a_hash,
      party_b: party_b_hash,
      contract_date: contract_date&.iso8601,
      start_on: start_on&.iso8601,
      end_on: end_on&.iso8601,
      articles: normalized_articles,
      special_terms: special_terms.to_s
    }.to_json
  end

  def freeze_body_when_signed_or_void
    return unless status_was.in?(%w[signed void])
    return if (changed & BODY_ATTRIBUTES).empty?

    errors.add(:base, "署名済みの契約書は変更できません")
    throw :abort
  end
end
