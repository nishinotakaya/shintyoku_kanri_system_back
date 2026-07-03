class AddDevLanguageToUsers < ActiveRecord::Migration[8.0]
  def up
    # 開発言語/スタック。全員 Ruby on Rails エンジニア。
    add_column :users, :dev_language, :string
    User.reset_column_information
    User.update_all(dev_language: "Ruby on Rails")
  end

  def down
    remove_column :users, :dev_language
  end
end
