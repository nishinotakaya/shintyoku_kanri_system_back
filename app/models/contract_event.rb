# Contract の追記専用の監査ログ。update/destroy する API・コードパスを設けない(create のみ)。
# 注: ActiveRecord の readonly? は destroy も止めてしまい、Contract の dependent: :destroy
# による正規のカスケード削除(下書き契約書の削除)まで壊すため、あえて使わない。
class ContractEvent < ApplicationRecord
  belongs_to :contract

  EVENTS = %w[created updated issued viewed signed voided duplicated pdf_viewed].freeze

  serialize :detail, coder: JSON

  validates :event, presence: true, inclusion: { in: EVENTS }
end
