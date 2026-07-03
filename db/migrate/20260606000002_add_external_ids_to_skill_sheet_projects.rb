class AddExternalIdsToSkillSheetProjects < ActiveRecord::Migration[8.0]
  def change
    # 外部求人プロフィールの連携先ID（重複防止・upsert 用）。
    add_column :skill_sheet_projects, :wantedly_work_experience_uuid, :string
    add_column :skill_sheet_projects, :anotherworks_resume_id, :string
  end
end
