class AddFeatureFlagsToUsers < ActiveRecord::Migration[8.0]
  def change
    # 機能フラグ (例: {"skill_sheet" => true})。SQLite なので text + serialize JSON。
    add_column :users, :feature_flags, :text
  end
end
