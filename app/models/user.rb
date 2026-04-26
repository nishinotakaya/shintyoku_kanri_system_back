class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :validatable,
         :omniauthable, :jwt_authenticatable,
         omniauth_providers: [:google_oauth2],
         jwt_revocation_strategy: JwtDenylist

  has_many :work_reports, dependent: :destroy
  has_many :expenses, dependent: :destroy
  has_many :invoice_settings, dependent: :destroy
  has_one  :backlog_setting, dependent: :destroy
  has_many :backlog_tasks, dependent: :destroy
  has_many :todos, dependent: :destroy
  has_many :monthly_settings, dependent: :destroy
  has_many :purchase_order_settings, dependent: :destroy

  def application_date_for(year, month)
    monthly_settings.find_by(year: year, month: month)&.application_date || Date.current
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
    to_day = [cd, Date.new(year, month, -1).day].min
    to = Date.new(year, month, to_day)
    from = to.prev_month + 1
    from..to
  end

  # Google OAuth でユーザーを検索 or 作成
  def self.from_google_oauth(auth)
    where(provider: auth.provider, uid: auth.uid).first_or_create! do |user|
      user.email = auth.info.email
      user.password = Devise.friendly_token[0, 20]
      user.display_name = auth.info.name
      user.avatar_url = auth.info.image
      user.company_name = auth.info.email.split("@").last.split(".").first.capitalize
    end
  end
end
