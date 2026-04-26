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
    issuer_name: ENV.fetch("DEFAULT_ISSUER_NAME", ""),
    registration_no: ENV.fetch("DEFAULT_REGISTRATION_NO", ""),
    postal_code: ENV.fetch("DEFAULT_POSTAL_CODE", ""),
    address: ENV.fetch("DEFAULT_ADDRESS", ""),
    tel: ENV.fetch("DEFAULT_TEL", ""),
    email: ENV.fetch("DEFAULT_EMAIL", ""),
    bank_info: ENV.fetch("DEFAULT_BANK_INFO", ""),
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
    client_name: "株式会社REシステムズ",
    subject: "",
    item_label: "開発支援業務",
    unit_price: 0,
    tax_rate: 0,
    payment_due_days: 7,
    default_items: [
      { "label" => "開発支援業務", "qty" => 1, "unit" => "式", "price" => 0 }
    ]
  ).freeze

  def self.defaults_for(category)
    case category.to_s
    when "techleaders" then TECHLEADERS_DEFAULTS
    when "resystems"   then RESYSTEMS_DEFAULTS
    else DEFAULTS
    end
  end
end
