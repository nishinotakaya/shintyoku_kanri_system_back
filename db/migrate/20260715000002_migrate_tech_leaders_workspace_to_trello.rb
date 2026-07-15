class MigrateTechLeadersWorkspaceToTrello < ActiveRecord::Migration[8.0]
  # builtin の「テックリーダーズ」ワークスペースを manual から trello 連携へ切り替える。
  def up
    execute(<<~SQL.squish)
      UPDATE progress_workspaces
      SET source_type = 'trello'
      WHERE builtin = 1 AND name = 'テックリーダーズ' AND source_type = 'manual'
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE progress_workspaces
      SET source_type = 'manual'
      WHERE builtin = 1 AND name = 'テックリーダーズ' AND source_type = 'trello'
    SQL
  end
end
