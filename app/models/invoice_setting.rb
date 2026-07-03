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

  def self.defaults_for(category)
    case category.to_s
    when "techleaders" then TECHLEADERS_DEFAULTS
    when "resystems"   then RESYSTEMS_DEFAULTS
    when "video"       then VIDEO_DEFAULTS
    else DEFAULTS
    end
  end

  # 注文書(PO)が無い時のフォールバック時給（カテゴリ別固定）。
  # 人別に保存された unit_price は使わず、カテゴリで一律にする方針。
  #   living(タマリビング)=3,750 / wings(タマ)=3,500 / それ以外(resystems/techleaders)=時給なし(0)
  CATEGORY_DEFAULT_UNIT_PRICE = { "living" => 3750, "wings" => 3500 }.freeze
  def self.default_unit_price_for(category)
    CATEGORY_DEFAULT_UNIT_PRICE[category.to_s].to_i
  end
end
