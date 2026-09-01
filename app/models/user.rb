class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :validatable,
         :omniauthable, :jwt_authenticatable,
         omniauth_providers: [ :google_oauth2 ],
         jwt_revocation_strategy: JwtDenylist

  has_many :work_reports, dependent: :destroy
  has_many :expenses, dependent: :destroy
  has_many :business_expenses, dependent: :destroy
  has_many :fixed_assets, dependent: :destroy
  has_many :bank_transactions, dependent: :destroy
  has_many :invoice_settings, dependent: :destroy
  # 請求先(宛先)マスタ。複数の取引先に請求書を出すユーザー(運送など)が登録する
  has_many :invoice_clients, dependent: :destroy
  has_one  :backlog_setting, dependent: :destroy
  has_one  :github_setting, dependent: :destroy
  has_many :backlog_tasks, dependent: :destroy
  has_many :progress_workspaces, dependent: :destroy
  has_many :user_data_source_permissions, dependent: :destroy
  # 自分のキーを貸している相手の権限。退職などで消えたら貸与を解除する(相手の権限行ごとは消さない)
  has_many :lent_data_source_permissions, class_name: "UserDataSourcePermission",
           foreign_key: :credential_owner_id, dependent: :nullify, inverse_of: :credential_owner
  has_many :backlog_activities, dependent: :destroy
  has_many :backlog_summary_notes, dependent: :destroy
  has_many :backlog_completions, dependent: :destroy
  has_many :todos, dependent: :destroy
  has_many :monthly_settings, dependent: :destroy
  has_many :purchase_order_settings, dependent: :destroy
  has_many :purchase_order_histories, dependent: :destroy
  has_many :received_purchase_orders, dependent: :destroy
  has_many :issued_invoice_pdfs, dependent: :destroy
  has_one  :freee_connection, dependent: :destroy
  has_many :scanned_invoices, dependent: :destroy
  has_one  :skill_sheet, dependent: :destroy
  has_many :interview_mindmaps, dependent: :destroy
  has_many :interview_videos, dependent: :destroy
  has_many :heygen_assets, dependent: :destroy
  has_many :contracts, dependent: :destroy
  has_many :tenant_memberships, dependent: :destroy
  has_many :tenants, through: :tenant_memberships
  has_many :owned_tenants, class_name: "Tenant", foreign_key: :owner_user_id, dependent: :nullify

  # サブ管理者の管理割当: manager → managee。
  # 例: 加藤(manager) が 岩切(managee) を管理する。川村は割り当てない＝管理対象外。
  has_many :manager_assignments, foreign_key: :manager_id, dependent: :destroy
  has_many :managees, through: :manager_assignments, source: :managee
  has_many :managed_by_assignments, class_name: "ManagerAssignment", foreign_key: :managee_id, dependent: :destroy

  # 機能フラグ (例: {"skill_sheet" => true})。SQLite なので text + serialize JSON。
  serialize :feature_flags, coder: JSON, type: Hash
  # カレンダーで予定行を出す人物名。空 = 既定メンバー
  serialize :calendar_persons, coder: JSON, type: Array
  # ユーザーごとに見せる勤怠カテゴリ(例: ["transport"])。nil = 従来どおり全カテゴリ(WorkReport::CATEGORIES)。
  serialize :work_categories, coder: JSON

  validate :work_categories_must_be_known_categories

  # 別アカウントを admin の同一人物としてリンク。
  # 例: wing西野 鷹也 (taka-nishino@tamahome.jp) を admin 西野 鷹也 (takaya314boxing@gmail.com) にリンク
  # → BaseController#current_user が linked_user に解決し、両アカウントから同一データを編集可能。
  belongs_to :linked_user, class_name: "User", optional: true

  def application_date_for(year, month)
    # 設定が無い場合は対象月の末日をデフォルトとする
    monthly_settings.find_by(year: year, month: month)&.application_date || Date.new(year.to_i, month.to_i, -1)
  end

  # 管理者判定: 表示名が「西野 鷹也」本人、または email が ADMIN_EMAILS に含まれる。
  # 以前は苗字「西野」を含むだけで管理者にしていたため、同姓のユーザー(西野 雄太郎)を
  # 追加した時点で全データが見える管理者になってしまう穴があった。
  ADMIN_EMAILS = %w[takaya314boxing@gmail.com taka-nishino@tamahome.jp].freeze
  ADMIN_DISPLAY_NAME = "西野 鷹也".freeze
  def admin?
    display_name.to_s.include?(ADMIN_DISPLAY_NAME) || ADMIN_EMAILS.include?(email.to_s.downcase)
  end

  # 統合帳票(請求書/立替金)の「主体」を決める並び替え。admin(西野) を必ず先頭にする。
  # 先頭のユーザーが差出人ブロック・印鑑・振込先になるため、順序が崩れると
  # 西野名義で出すべき統合PDFに川村さんのハンコが押されてしまう。
  # DL・メール添付など生成経路が複数あるので、順序の決定はここ 1 箇所に集約する。
  def self.admin_first(users)
    users.to_a.uniq.partition(&:admin?).flatten
  end

  # 通知の宛先や請求書の宛名に使う主管理者(西野 鷹也)。苗字 LIKE で探すと同姓の別人(西野 雄太郎)も
  # 拾うので、管理者メール → 氏名の順で決める。
  def self.primary_admin
    by_email = ADMIN_EMAILS.filter_map { |email| find_by(email: email) }.first
    by_email || where("display_name LIKE ?", "%#{ADMIN_DISPLAY_NAME}%").order(:id).first
  end

  # 機能を使えるか。admin は明示的に false にされた機能以外は使える、フラグ ON のユーザーも true。
  # 免税事業者か（消費税の納税なし・インボイス未登録前提）。税務アドバイス等の前提を切り替える。
  def exempt_business? = tax_status == "exempt"

  def can_use?(feature)
    return feature_flags.to_h[feature.to_s] != false if admin?
    feature_flags.to_h[feature.to_s] == true
  end

  # 進捗管理の外部データソース(backlog / notion / trello)の権限。
  # レコードが無ければ不可(fail-closed)。admin は全ソースを扱える。
  # find(Enumerable)で引くのは、関連のキャッシュに乗せて reload でも正しく捨てさせるため。
  def data_source_permission(source_type)
    user_data_source_permissions.find { |permission| permission.source_type == source_type.to_s }
  end

  def can_view_data_source?(source_type)
    return true if admin?
    data_source_permission(source_type)&.can_view == true
  end

  def can_sync_data_source?(source_type)
    return true if admin?
    data_source_permission(source_type)&.can_sync == true
  end

  # 外部サービス(Backlog など)へ書き込めるか。借りたキーでの書き込みは既定で不可。
  def can_write_data_source?(source_type)
    return true if admin?
    data_source_permission(source_type)&.can_write == true
  end

  def viewable_data_source_types
    UserDataSourcePermission::SOURCE_TYPES.select { |source_type| can_view_data_source?(source_type) }
  end

  # カレンダーに予定行を出す人物名。管理者が /users で設定でき、未設定なら次の既定になる。
  # - テナント(会社)に紐づくユーザー: 自分 + 自分が代表のテナントに紐づくメンバーだけ
  # - 西野さん・川村さん: 既定メンバー全員(お互いの予定を見る従来どおりの運用)
  # - それ以外: 自分の予定だけ
  def visible_calendar_persons
    configured = calendar_persons.to_a.map(&:to_s).reject(&:empty?)
    return configured if configured.present?
    return tenant_calendar_persons if belongs_to_any_tenant?
    return TeamSchedule::DEFAULT_PERSONS if sees_whole_team_calendar?

    [ own_calendar_person ].reject(&:empty?)
  end

  # テナント(会社)単位のカレンダー。代表は自分と配下メンバー、メンバーは自分だけを見る。
  # 配下メンバーが未登録なら自分1人だけ(HAUKUR運送の現状)。
  def tenant_calendar_persons
    member_ids = TenantMembership.where(tenant_id: owned_tenants.select(:id)).pluck(:user_id)
    members = User.where(id: member_ids).where.not(id: id).order(:id)
    ([ self ] + members.to_a).map(&:own_calendar_person).reject(&:empty?).uniq
  end

  # 代表・メンバーのいずれかでテナントに紐づいているか
  def belongs_to_any_tenant?
    owned_tenants.exists? || tenant_memberships.exists?
  end

  # team_schedules の person 名(苗字)に相当する自分の名前。
  # 同じ人物名を名乗れるユーザーが複数いる場合(「西野」= 西野 鷹也さん / 西野 雄太郎さん)、
  # 先に登録されたユーザーがその人物行の持ち主。後から入ったユーザーはフルネームを人物名にして、
  # 他人の予定行に相乗りしないようにする。
  def own_calendar_person
    # /me は 1 リクエスト中に visible/own/editable を続けて呼ぶので、都度クエリを撃たないよう覚えておく
    return @own_calendar_person if defined?(@own_calendar_person)

    name = display_name.to_s
    candidate = TeamSchedule.selectable_persons.find { |person| name.include?(person) }
    return @own_calendar_person = name.split(/[[:space:]]+/).first.to_s if candidate.blank?

    earliest_rival_id = same_person_name_users(candidate).minimum(:id)
    @own_calendar_person =
      if earliest_rival_id.nil? || (id.present? && id < earliest_rival_id)
        candidate
      else
        name
      end
  end

  # 人物行(team_schedules.person)を編集できるか。
  # 「川村」行×「川村 卓也」のような表記ゆれは許容するが、その人物名を自分のものとして
  # 持っている別ユーザー(同姓の先輩。例:「西野」= 西野 鷹也さん)の行には触れさせない。
  def can_edit_calendar_person?(person_name)
    return true if admin?

    person_name = person_name.to_s
    own = own_calendar_person
    return false if person_name.blank? || own.blank?
    return true if person_name == own
    return false unless person_name.include?(own) || own.include?(person_name)

    # その人物名を自分の行として持っている別ユーザーがいれば他人の行。
    # 候補は同じ名前を含むユーザーだけなので、全ユーザーは走査しない。
    same_person_name_users(person_name).none? { |other| other.own_calendar_person == person_name }
  end

  # person_name を人物名として名乗りうる自分以外のユーザー
  def same_person_name_users(person_name)
    User.where("display_name LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(person_name)}%")
        .where.not(id: id)
  end

  # 見える人物行のうち、自分で操作できるもの(フロントの編集可否もこれに従う)
  def editable_calendar_persons
    visible_calendar_persons.select { |person| can_edit_calendar_person?(person) }
  end

  # 所属する会社(テナント)名。カレンダーの見出しに出す。
  # 人物行そのものは本人の名前のまま(「西野 雄太郎」)で、会社名は上の見出しに置く。
  # 代表を務める会社を優先し、無ければメンバーとして所属する会社。
  def tenant_name
    (owned_tenants.first || tenants.first)&.name
  end

  def sees_whole_team_calendar?
    TeamSchedule::FULL_CALENDAR_PERSONS.include?(own_calendar_person)
  end

  # このユーザーに見せる勤怠カテゴリ。未設定(nil)なら従来どおり全カテゴリを見せる。
  # 例: 西野 雄太郎(運送業) は work_categories=["transport"] で「運送」だけを見る。
  def visible_work_categories
    Array(work_categories).presence || WorkReport::CATEGORIES
  end

  # 閲覧できないデータソース。タブやタスク一覧から外す判定に使う。
  def hidden_data_source_types
    UserDataSourcePermission::SOURCE_TYPES - viewable_data_source_types
  end

  # API キーの持ち主。他人から借りている場合はその人、既定は自分。
  def credential_owner_for(source_type)
    owner_id = data_source_permission(source_type)&.credential_owner_id
    return self if owner_id.nil?
    ::User.find_by(id: owner_id) || self
  end

  # Backlog 接続に使う設定。認証情報だけ貸し元から借り、担当者フィルタ等の個人設定は自分のものを使う。
  # 借用時は保存しない複製を返すので、うっかり貸し元の設定を書き換えることはない。
  def backlog_connection_setting
    own_setting = backlog_setting || build_backlog_setting(BacklogSetting::DEFAULTS)
    owner = credential_owner_for("backlog")
    return own_setting if owner.id == id

    # 貸し元のキーが空なら借りずに自分の設定で動かす。貸し元の設定漏れで、それまで
    # 動いていた同期が止まる方が事故として重い。
    owner_setting = owner.backlog_setting
    return own_setting if owner_setting&.api_key.blank?

    own_setting.dup.tap do |borrowed|
      borrowed.backlog_url = owner_setting.backlog_url
      borrowed.backlog_email = owner_setting.backlog_email
      borrowed.api_key = owner_setting.api_key
      borrowed.board_id = owner_setting.board_id
    end
  end

  # 代表(owned_tenants)もメンバー(tenants)も含めて所属する全テナント。
  def belonging_tenants
    Tenant.where(id: owned_tenants.pluck(:id) + tenants.pluck(:id))
  end

  # 誰かを管理しているサブ管理者か (admin は別枠)。
  def sub_admin?
    !admin? && manager_assignments.exists?
  end

  # このユーザーが閲覧・編集できる対象ユーザーの id 一覧。
  # - admin (西野): 全ユーザー
  # - サブ管理者 (加藤): 割り当てられた managee + 自分
  # - 一般ユーザー: 自分のみ
  def manageable_user_ids
    return ::User.ids if admin?
    (managees.pluck(:id) + [ id ]).uniq
  end

  def can_manage_user?(target_user_id)
    manageable_user_ids.include?(target_user_id.to_i)
  end

  # 請求書/立替金 PDF のデフォルト宛先名。
  # - admin (西野): エンドの取引先「株式会社ラボップ」
  # - 非admin (川村): 直接の発注元である admin (西野) の display_name
  # 個別の上書き (シェアラウンジ宛名固定 / 明示 client_name_override) はこの結果を更に上書きする
  def invoice_recipient_name
    if admin?
      I18n.t("companies.labop.name")
    else
      self.class.primary_admin&.display_name.to_s.strip.presence || ADMIN_DISPLAY_NAME
    end
  end

  def invoice_recipient_honorific
    admin? ? "御中" : "様"
  end

  # 登録済みの請求先マスタの既定。請求書に宛先が明示されていない時のフォールバックに使う。
  # マスタを登録していないユーザー(従来どおりの人)は nil になり、挙動は変わらない。
  def default_invoice_client
    invoice_clients.active.ordered.find_by(is_default: true)
  end

  def invoice_setting_for(category = "wings")
    invoice_settings.find_by(category: category) || build_invoice_setting_for(category)
  end

  # 発行者の身元情報(氏名/インボイス番号/住所/連絡先/口座)はカテゴリに依らず本人固有。
  # 未作成カテゴリの設定を組み立てる際は、本人の既存設定から引き継いで空欄にしない。
  # (例: 西野が須崎(video)への支払通知書を出すとき、西野に video 設定が無くても Tel/インボイス番号を出す)
  ISSUER_IDENTITY_FIELDS = %i[issuer_name registration_no postal_code address tel email bank_info].freeze
  def build_invoice_setting_for(category)
    attrs = InvoiceSetting.defaults_for(category).merge(category: category)
    source = invoice_settings.detect { |setting| setting.issuer_name.present? } || invoice_settings.first
    if source
      ISSUER_IDENTITY_FIELDS.each do |field|
        value = source.public_send(field)
        attrs[field] = value if value.present?
      end
    end
    # テナントのメンバー(外注ドライバー等)は、代表の同カテゴリ設定から 税込/税抜 を引き継ぐ。
    # 代表(雄太郎)が税込で回している商流なら、外注側の請求書も最初から税込で揃う。
    owner_setting = tenant_owner_invoice_setting(category)
    attrs[:tax_included] = owner_setting.tax_included if owner_setting
    invoice_settings.build(attrs)
  end

  # メンバーとして所属するテナントの代表が持つ、同カテゴリの請求書設定(無ければ nil)。代表本人は対象外。
  def tenant_owner_invoice_setting(category)
    owner = tenants.first&.owner_user
    return nil if owner.nil? || owner == self
    owner.invoice_settings.find_by(category: category)
  end

  serialize :custom_off_days, coder: JSON, type: Array
  serialize :transit_routes, coder: JSON, type: Array  # [{from,to,fee,line}]
  serialize :commute_days, coder: JSON, type: Array    # [1,3,5] = 月水金

  validates :closing_day, inclusion: { in: 1..31 }

  # 締日ベースの対象期間(例: 25日締めの2026年9月度 = 2026-08-26..2026-09-25)。
  # 締日が月末日を超える月は月末日に丸める(31日締め = 末日締め)。
  # 開始日は「前月度の締日の翌日」。to.prev_month + 1 で求めると、月末日に丸めた
  # 月で1日ずれる(末日締めの9月度が 8/31 始まりになる・30日締めの3月度が 2/28 と重なる)。
  def period_for(year, month)
    to = closing_date_of(year, month)
    previous_month = Date.new(year, month, 1).prev_month
    from = closing_date_of(previous_month.year, previous_month.month).next_day
    from..to
  end

  # その月の締日。締日が月末日より後ろなら月末日に丸める。
  def closing_date_of(year, month)
    effective_closing_day = closing_day || 25
    last_day_of_month = Date.new(year, month, -1).day
    Date.new(year, month, [ effective_closing_day, last_day_of_month ].min)
  end

  # 他ユーザーのデータをコピーして初期化したいメールアドレスのマップ
  # 例: 新ユーザー(calmdownyourlife) を作る際に kawamura のデータを丸ごと引き継ぐ
  CLONE_FROM_ON_CREATE = {
    "calmdownyourlife@gmail.com" => "kawamura@gmail.com"
  }.freeze

  # 別 email でログインしても同じ User レコードに紐付けたいエイリアス。
  # 値(primary email) のユーザに合流する。例: 会社用と個人用で別 Google アカウント運用するケース。
  EMAIL_ALIASES = {
    "taka-nishino@tamahome.jp" => "takaya314boxing@gmail.com"
  }.freeze

  # Google OAuth でユーザーを検索 or 作成
  def self.from_google_oauth(auth)
    user = where(provider: auth.provider, uid: auth.uid).first
    return user if user

    # email alias がある場合は primary email に解決して既存ユーザに合流
    incoming_email = auth.info.email.to_s.downcase
    primary_email = EMAIL_ALIASES[incoming_email] || incoming_email

    # primary email の既存ユーザがいれば、provider/uid を紐付け直して返す
    # (再同意 / OAuth クライアント変更で uid が変わった場合のリカバリも兼ねる)
    if (existing = where(email: primary_email).first)
      existing.update!(
        provider: auth.provider,
        uid: auth.uid,
        google_access_token: nil # トークンは callback 側で改めて入る
      )
      return existing
    end

    user = create! do |new_user|
      new_user.provider = auth.provider
      new_user.uid = auth.uid
      new_user.email = auth.info.email
      new_user.password = Devise.friendly_token[0, 20]
      new_user.display_name = auth.info.name
      new_user.avatar_url = auth.info.image
      new_user.company_name = auth.info.email.split("@").last.split(".").first.capitalize
    end

    src_email = CLONE_FROM_ON_CREATE[user.email]
    if src_email && (src = User.find_by(email: src_email))
      UserCloner.copy_all(src: src, dst: user)
    end

    user
  end

  private

  # work_categories の各要素が WorkReport::CATEGORIES に含まれるか。nil/空配列は許容(=従来どおり全カテゴリ)。
  def work_categories_must_be_known_categories
    return if work_categories.blank?
    unknown = Array(work_categories) - WorkReport::CATEGORIES
    return if unknown.empty?
    errors.add(:work_categories, "に不正なカテゴリが含まれています: #{unknown.join(', ')}")
  end
end
