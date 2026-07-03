class AddSourceToSkillSheetProjects < ActiveRecord::Migration[8.0]
  def change
    # 案件の出所。'import'=スプレッドシート取り込み / 'backlog'=Backlog実績から生成。
    # インポート時は 'backlog' を保持し 'import' だけ入れ替える（Backlog生成分を消さない）。
    add_column :skill_sheet_projects, :source, :string, default: "import", null: false
  end
end
