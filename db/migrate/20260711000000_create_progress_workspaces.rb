class CreateProgressWorkspaces < ActiveRecord::Migration[8.0]
  # 進捗管理(/progress)のワークスペース切替。ユーザーごとに Wing/リビング/テックリーダーズ/
  # ReRe/プライベートの5個をデフォルトとし、backlog_tasks を所属させる。
  def change
    create_table :progress_workspaces do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :name, null: false
      t.string  :source_type, null: false, default: "manual" # backlog / notion / manual
      t.boolean :builtin, null: false, default: false
      t.integer :position, default: 0
      t.timestamps
    end

    add_column :backlog_tasks, :progress_workspace_id, :integer
    add_index  :backlog_tasks, :progress_workspace_id

    # 既存 backlog_tasks を持つ各ユーザーにデフォルト5ワークスペースを作成し、
    # 既存タスク全件を builtin の Wing(backlog) ワークスペースへ紐付ける。
    # (migration はアプリのモデル定義に依存させず、デフォルト値はここに直接持つ。
    #  ProgressWorkspace::DEFAULTS と内容を揃えること)
    reversible do |dir|
      dir.up do
        default_workspaces = [
          { name: "Wing", source_type: "backlog" },
          { name: "リビング", source_type: "notion" },
          { name: "テックリーダーズ", source_type: "manual" },
          { name: "ReRe", source_type: "manual" },
          { name: "プライベート", source_type: "manual" }
        ]

        user_ids_with_tasks = execute("SELECT DISTINCT user_id FROM backlog_tasks").map { |row| row["user_id"] }
        user_ids_with_tasks.each do |user_id|
          wing_workspace_id = nil
          default_workspaces.each_with_index do |default_workspace, index|
            execute(<<~SQL.squish)
              INSERT INTO progress_workspaces (user_id, name, source_type, builtin, position, created_at, updated_at)
              VALUES (#{user_id}, #{quote(default_workspace[:name])}, #{quote(default_workspace[:source_type])}, 1, #{index}, datetime('now'), datetime('now'))
            SQL
            inserted_id = execute("SELECT last_insert_rowid() AS id").first["id"]
            wing_workspace_id = inserted_id if default_workspace[:source_type] == "backlog"
          end

          execute(<<~SQL.squish)
            UPDATE backlog_tasks SET progress_workspace_id = #{wing_workspace_id} WHERE user_id = #{user_id}
          SQL
        end
      end
    end
  end
end
