class AddSheetUrlToProgressWorkspaces < ActiveRecord::Migration[8.0]
  def up
    # 進捗のスプレッドシートは Wing / リビング など案件ごとに別物なので、
    # ユーザー単位の users.progress_sheet_url ではなくワークスペース単位で持つ。
    add_column :progress_workspaces, :sheet_url, :string

    # 既存の users.progress_sheet_url は Wing(Tama)の進捗シートとして使われていたので、
    # 各ユーザーの先頭ワークスペース(Wing)へ引き継ぐ。
    execute <<~SQL
      UPDATE progress_workspaces
         SET sheet_url = (SELECT users.progress_sheet_url FROM users WHERE users.id = progress_workspaces.user_id)
       WHERE progress_workspaces.builtin = 1
         AND progress_workspaces.position = 0
         AND (SELECT users.progress_sheet_url FROM users WHERE users.id = progress_workspaces.user_id) IS NOT NULL
    SQL
  end

  def down
    remove_column :progress_workspaces, :sheet_url
  end
end
