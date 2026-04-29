class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :validatable,
         :omniauthable, :jwt_authenticatable,
         omniauth_providers: [ :google_oauth2 ],
         jwt_revocation_strategy: JwtDenylist

  has_many :work_reports, dependent: :destroy
  has_many :expenses, dependent: :destroy
  has_many :invoice_settings, dependent: :destroy
  has_one  :backlog_setting, dependent: :destroy
  has_many :backlog_tasks, dependent: :destroy
  has_many :todos, dependent: :destroy
  has_many :monthly_settings, dependent: :destroy
  has_many :purchase_order_settings, dependent: :destroy
  has_many :purchase_order_histories, dependent: :destroy

  def application_date_for(year, month)
    monthly_settings.find_by(year: year, month: month)&.application_date || Date.current
  end

  # 管理者判定: 表示名に「西野」を含む、または email が ADMIN_EMAILS に含まれる
  ADMIN_EMAILS = %w[takaya314boxing@gmail.com taka-nishino@tamahome.jp].freeze
  def admin?
    display_name.to_s.include?("西野") || ADMIN_EMAILS.include?(email.to_s.downcase)
  end

  def invoice_setting_for(category = "wings")
    invoice_settings.find_by(category: category) ||
      invoice_settings.build(InvoiceSetting.defaults_for(category).merge(category: category))
  end

  serialize :custom_off_days, coder: JSON, type: Array
  serialize :transit_routes, coder: JSON, type: Array  # [{from,to,fee,line}]
  serialize :commute_days, coder: JSON, type: Array    # [1,3,5] = 月水金

  validates :closing_day, inclusion: { in: 1..31 }

  def period_for(year, month)
    cd = closing_day || 25
    to_day = [ cd, Date.new(year, month, -1).day ].min
    to = Date.new(year, month, to_day)
    from = to.prev_month + 1
    from..to
  end

  # 他ユーザーのデータをコピーして初期化したいメールアドレスのマップ
  # 例: 新ユーザー(calmdownyourlife) を作る際に kawamura のデータを丸ごと引き継ぐ
  CLONE_FROM_ON_CREATE = {
    "calmdownyourlife@gmail.com" => "kawamura@gmail.com"
  }.freeze

  # Google OAuth でユーザーを検索 or 作成
  def self.from_google_oauth(auth)
    user = where(provider: auth.provider, uid: auth.uid).first
    return user if user

    # 同じ email の既存ユーザがいれば、provider/uid を紐付け直して返す
    # (再同意 / OAuth クライアント変更などで uid が変わった場合のリカバリ)
    if (existing = where(email: auth.info.email).first)
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
end
