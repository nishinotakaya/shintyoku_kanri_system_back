class InvoiceSetting < ApplicationRecord
  belongs_to :user

  serialize :default_items, coder: JSON, type: Array
  # 統合請求書(ラボップ宛)だけに載せる固定明細。未設定なら default_items を流用する。
  serialize :merged_default_items, coder: JSON, type: Array

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

  # 税込/税抜(tax_included)。false=税抜(既定。明細合計に消費税を加算) / true=税込(明細の単価・金額が税込で、
  # 合計=明細合計、消費税は内税として ÷(1+税率) で逆算)。西野・川村は税抜、運送(雄太郎)は税込。
  #
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

  # 時間外の割増率。労基法の時間外割増(25%)に合わせる
  OVERTIME_PREMIUM_RATE = 1.25

  # 超過時給の既定 = 日給 ÷ 所定時間 × 1.25(例: 日給 17,000 / 8h → 基礎時給 2,125 × 1.25 = 2,656)。
  # 日給が無ければ nil
  def default_overtime_unit_price
    return nil unless daily_rate.to_i.positive?
    (daily_rate.to_i / standard_hours_per_day * OVERTIME_PREMIUM_RATE).round
  end

  # 請求計算に使う超過時給。入力があればそれ、未入力(または 0)なら既定値
  def effective_overtime_unit_price
    overtime_unit_price.to_i.positive? ? overtime_unit_price.to_i : default_overtime_unit_price.to_i
  end

  # 画面・ファイル名で使うカテゴリの表示名。帳票名やフォルダ名の先頭に付く。
  CATEGORY_LABELS = {
    "wings" => "Wings",
    "living" => "リビング",
    "techleaders" => "テックリーダーズ",
    "resystems" => "REシステムズ",
    "video" => "動画編集",
    "proaka" => "プロアカ",
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

  # 統合請求書に載せる固定明細(シェアラウンジ控除など)。
  #   ① 本人設定の merged_default_items(請求側専用)
  #   ② 無ければ default_items(支払側と請求側が同じ人。admin=西野がこれ)
  # default_items をそのまま請求側に流用すると、本人への支払額からも控除されてしまうため、
  # 「請求側だけ控除する人(川村さん)」は ① に入れる。
  def self.billing_default_items_for(user, category)
    setting = user.invoice_settings.find_by(category: category.to_s)
    return [] if setting.nil?
    Array(setting.merged_default_items).presence || Array(setting.default_items)
  end
end
