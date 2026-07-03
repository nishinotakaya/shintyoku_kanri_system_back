class AddTitleToSkillSheetProjects < ActiveRecord::Migration[8.0]
  def change
    # プロジェクト名(■で書いていた案件名)。業務内容(description)と分離する。
    add_column :skill_sheet_projects, :title, :string
  end
end
