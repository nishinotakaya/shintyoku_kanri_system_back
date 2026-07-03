class AddJobProfileTokensToUsers < ActiveRecord::Migration[8.0]
  def change
    # 外部求人プロフィール連携用トークン（Wantedly Bearer / 副業クラウド Firebase IDトークン）。
    # 既存の google_access_token 等と同じく text で保持（短命・UIから更新）。
    add_column :users, :wantedly_token, :text
    add_column :users, :anotherworks_token, :text
  end
end
