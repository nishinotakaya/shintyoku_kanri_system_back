class AddFreeeSyncedToBusinessExpenses < ActiveRecord::Migration[8.0]
  def change
    # freee_synced: この経費が freee に存在するか。
    #   true  = freee から取り込んだ or freee へ連携済み
    #   false = このシステムだけで登録(まだ freee に無い) → 連携候補
    add_column :business_expenses, :freee_synced, :boolean, default: false, null: false
  end
end
