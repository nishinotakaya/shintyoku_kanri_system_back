class CreateSkillSheetProjects < ActiveRecord::Migration[8.0]
  def change
    # 職務経歴の 1 案件。
    create_table :skill_sheet_projects do |t|
      t.integer :skill_sheet_id, null: false
      t.integer :position, default: 0
      t.string  :period_from
      t.string  :period_to
      t.text    :description   # 業務内容
      t.text    :role_scale    # 役割・規模
      t.text    :languages     # 使用言語
      t.text    :db
      t.text    :server_os
      t.text    :tools         # FW・MW・ツール
      t.text    :phases        # 担当工程の bool マップ (JSON)
      t.timestamps
    end
    add_index :skill_sheet_projects, [ :skill_sheet_id, :position ]
  end
end
