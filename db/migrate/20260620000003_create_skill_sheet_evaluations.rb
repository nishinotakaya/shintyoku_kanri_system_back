class CreateSkillSheetEvaluations < ActiveRecord::Migration[8.0]
  # スキル評価グリッド(クリエイターテンプレの「評価レベル A〜E」)の保存先。
  # label = グリッドのスキル名(例: Photoshop / HTML5 / React.js)、level = A〜E。
  def change
    create_table :skill_sheet_evaluations do |t|
      t.references :skill_sheet, null: false, foreign_key: true
      t.string :label, null: false # グリッドのスキル名
      t.string :level, null: false # A / B / C / D / E
      t.timestamps
    end
    add_index :skill_sheet_evaluations, [ :skill_sheet_id, :label ], unique: true
  end
end
