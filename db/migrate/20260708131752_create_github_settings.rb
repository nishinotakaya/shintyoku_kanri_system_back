class CreateGithubSettings < ActiveRecord::Migration[8.0]
  def up
    create_table :github_settings do |t|
      t.references :user, null: false, foreign_key: true
      t.string :personal_access_token
      t.text :default_repos

      t.timestamps
    end

    # 西野さん(admin)の初期表示リポジトリを設定しておく。トークンは未設定のまま(ユーザーが後で登録)。
    nishino = User.find_by(email: "takaya314boxing@gmail.com")
    if nishino
      GithubSetting.create!(
        user: nishino,
        default_repos: "1107t/tech-put-app\nnishinotakay/teac-output-new"
      )
    end
  end

  def down
    drop_table :github_settings
  end
end
