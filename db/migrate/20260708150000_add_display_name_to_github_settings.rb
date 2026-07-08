class AddDisplayNameToGithubSettings < ActiveRecord::Migration[8.0]
  # GitHub パネルの見出しをユーザーが自分の分かりやすい名前に変えられるようにする
  def change
    add_column :github_settings, :display_name, :string
  end
end
