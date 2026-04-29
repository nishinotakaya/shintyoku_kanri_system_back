# 発注書を発行した瞬間のスナップショット (payload JSON) を保持する履歴テーブル。
# 設定 (purchase_order_settings) は上書きされるので、過去の発注を再現できるようにこちらに保存。
class PurchaseOrderHistory < ApplicationRecord
  belongs_to :user
  serialize :payload, coder: JSON
end
