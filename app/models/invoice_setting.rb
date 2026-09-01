class InvoiceSetting < ApplicationRecord
  belongs_to :user

  serialize :default_items, coder: JSON, type: Array

  # 既定値（個人情報は ENV から注入。Public リポジトリに具体値を残さない）
  DEFAULTS = {
    client_name: ENV.fetch("DEFAULT_CLIENT_NAME", ""),
    subject: ENV.fetch("DEFAULT_INVOICE_SUBJECT", ""),
    item_label: "開発支援業務",
    unit_price: ENV.fetch("DEFAULT_UNIT_PRICE", "3750").to_i,
    tax_rate: 10,
    payment_due_days: 35,
    # 発行者の身元情報(氏名/インボイス番号/住所/連絡先/口座)は個人情報。
    # 他人(管理者=西野)の既定を継承しないよう必ず空で始める。各ユーザーが設定で自分の情報を入力する。
    issuer_name: "",
    registration_no: "",
    postal_code: "",
    address: "",
    tel: "",
    email: "",
    bank_info: "",
    default_items: [
      { "label" => "シェアラウンジ利用料", "qty" => 1, "unit" => "回", "price" => -30000 }
    ]
  }.freeze

  TECHLEADERS_DEFAULTS = DEFAULTS.merge(
    client_name: "株式会社テックリーダーズ",
    subject: "",
    item_label: "プロアカ歩合報酬",
    unit_price: 0,
    tax_rate: 0,
    payment_due_days: 5,
    default_items: [
      { "label" => "プロアカ歩合報酬", "qty" => 1, "unit" => "式", "price" => 0 }
    ]
  ).freeze

  RESYSTEMS_DEFAULTS = DEFAULTS.merge(
    client_name: "株式会社ReReシステムズ",
    subject: "",
    item_label: "開発支援業務",
    unit_price: 0,
    tax_rate: 0,
    payment_due_days: 7,
    # 既定明細は入れない。新規作成後に編集モーダルから自分で明細を追加する運用。
    # (旧: 「開発支援業務 1式 0円」を自動挿入していたが、作業者名が前置された謎の 0 円行になるため廃止)
    default_items: []
  ).freeze

  # 動画編集(須崎さん等)。時給概念なし → 明細は手入力。税率10%。
  VIDEO_DEFAULTS = DEFAULTS.merge(
    client_name: "",
    subject: "",
    item_label: "動画編集業務",
    unit_price: 0,
    tax_rate: 10,
    default_items: []
  ).freeze

  # 運送(西野 雄太郎等)。時給概念なし → 明細は手入力。税率10%。
  TRANSPORT_DEFAULTS = DEFAULTS.merge(
    client_name: "",
    subject: "",
    item_label: "運送業務",
    unit_price: 0,
    tax_rate: 10,
    default_items: []
  ).freeze

  # 報酬形態。運送(transport)だけが選べる。
  #   hourly = 稼働時間 × 時給(unit_price)
  #   daily  = 稼働日数 × 日給(daily_rate) + 所定時間(standard_hours)超過分 × 超過時給(overtime_unit_price)
  PAY_TYPES = %w[hourly daily].freeze
  DEFAULT_STANDARD_HOURS = 8.0

  def effective_pay_type
    PAY_TYPES.include?(pay_type.to_s) ? pay_type.to_s : "hourly"
  end

  def daily_pay?
    effective_pay_type == "daily"
  end

  # 1日の所定時間。未設定なら 8 時間
  def standard_hours_per_day
    standard_hours.to_f.positive? ? standard_hours.to_f : DEFAULT_STANDARD_HOURS
  end

  # 画面・ファイル名で使うカテゴリの表示名。帳票名やフォルダ名の先頭に付く。
  CATEGORY_LABELS = {
    "wings" => "Wings",
    "living" => "リビング",
    "techleaders" => "テックリーダーズ",
    "resystems" => "REシステムズ",
    "video" => "動画編集",
    "transport" => "運送"
  }.freeze

  def self.category_label(category)
    CATEGORY_LABELS[category.to_s]
  end

  def self.defaults_for(category)
    case category.to_s
    when "techleaders" then TECHLEADERS_DEFAULTS
    when "resystems"   then RESYSTEMS_DEFAULTS
    when "video"       then VIDEO_DEFAULTS
    when "transport"   then TRANSPORT_DEFAULTS
    else DEFAULTS
    end
  end

  # 注文書(PO)が無い時のフォールバック時給（カテゴリ別固定）。
  # 人別に保存された unit_price は使わず、カテゴリで一律にする方針。
  #   living(タマリビング)=3,750 / wings(タマ)=3,750 / それ以外(resystems/techleaders)=時給なし(0)
  # wings は 2026-07 に西野さんの指示で 3,500→3,750 に変更(西野さんの実レート)。
  # living(ラボップ宛の統合請求書)は 3,750 円。川村さんへ発行する注文書は 3,250 円だが、
  # それは purchase_order_settings.rate_per_hour 側で持つ(注文書の期間が切れているとここに落ちて
  # 3,750 円になるので、注文書は期間を切らさず登録すること)。
  # 川村さん等の個別レートは請求額(total_override)や注文書レートで設定されるためデフォルトに依存しない。
  CATEGORY_DEFAULT_UNIT_PRICE = { "living" => 3750, "wings" => 3750 }.freeze
  def self.default_unit_price_for(category)
    CATEGORY_DEFAULT_UNIT_PRICE[category.to_s].to_i
  end

  # 統合請求書(ラボップ宛)でこの人の稼働に掛ける時給。支払側の時給とは別レート。
  #   ① 本人設定の merged_unit_price(admin が as_user_id で設定できる)
  #   ② admin 本人は自分の unit_price(=自分の売りレート)
  #   ③ カテゴリ既定(wings/living=3,750)
  def self.billing_unit_price_for(user, category)
    setting = user.invoice_settings.find_by(category: category.to_s)
    rate = setting&.merged_unit_price.to_i
    return rate if rate.positive?
    if user.admin?
      own = setting&.unit_price.to_i
      return own if own.positive?
    end
    default_unit_price_for(category)
  end
end
