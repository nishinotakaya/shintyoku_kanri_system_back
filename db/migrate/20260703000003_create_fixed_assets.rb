class CreateFixedAssets < ActiveRecord::Migration[8.0]
  # 減価償却資産(確定申告支援用)。定額法・月割で年間償却費を自動計算する。
  def change
    create_table :fixed_assets do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false             # 資産名 (例: MacBook Pro)
      t.date    :acquired_on, null: false      # 取得日
      t.integer :cost, null: false             # 取得価額(円)
      t.integer :useful_life_years, null: false # 耐用年数
      t.integer :business_ratio, default: 100, null: false # 事業使用割合(%)
      t.string  :memo
      t.timestamps
    end
    add_index :fixed_assets, :user_id
  end
end
