class AddVideoScriptContextToUsers < ActiveRecord::Migration[8.0]
  def change
    # 動画台本AI生成に使う「プロフィール・事業内容(プロアカ等)」。スキルシートに無い文脈を補う。
    add_column :users, :video_script_context, :text
  end
end
