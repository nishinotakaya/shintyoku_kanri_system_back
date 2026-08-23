class AddNameKanaToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :name_kana, :string # 申告書のフリガナ欄用(カタカナ)
  end
end
