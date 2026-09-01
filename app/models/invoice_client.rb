# 請求先(宛先)マスタ。「取引先 → 自分 → 外注」の中間に立つユーザーが、
# 複数の取引先を登録しておき請求書ごとに選べるようにするための正本。
# 過去の請求書が参照するため削除は物理削除せずアーカイブする。
class InvoiceClient < ApplicationRecord
  belongs_to :user

  HONORIFICS = %w[御中 様].freeze

  validates :name, presence: true
  validates :honorific, inclusion: { in: HONORIFICS }, allow_blank: true

  scope :active, -> { where(archived_at: nil) }
  scope :ordered, -> { order(is_default: :desc, position: :asc, id: :asc) }

  before_save :unset_other_defaults, if: -> { is_default? && (new_record? || will_save_change_to_is_default?) }

  def archive!
    update!(archived_at: Time.current, is_default: false)
  end

  def display_honorific
    honorific.presence || "御中"
  end

  private

  # 既定の請求先はユーザーごとに1件だけ
  def unset_other_defaults
    user.invoice_clients.where.not(id: id).where(is_default: true).update_all(is_default: false)
  end
end
