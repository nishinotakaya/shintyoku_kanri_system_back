# マイナンバーカード撮影→AI読取で取得した個人番号(暗号化して保存)と生年月日を保持する。
# my_number は Active Record Encryption の暗号文が入るため text カラムにする。
class AddMyNumberAndBirthDateToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :my_number, :text
    add_column :users, :birth_date, :date
  end
end
