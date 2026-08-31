class AddWorkCategoriesToUsers < ActiveRecord::Migration[8.0]
  def change
    # ユーザーごとに見せる勤怠カテゴリ(JSON配列)。nil = 従来どおり全カテゴリ(WorkReport::CATEGORIES)。
    # 例: 西野 雄太郎(軽貨物運送) = ["transport"]
    add_column :users, :work_categories, :text
  end
end
