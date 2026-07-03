class CreateSkillSheetReviewItems < ActiveRecord::Migration[8.0]
  def change
    create_table :skill_sheet_review_items do |t|
      t.references :skill_sheet, null: false, foreign_key: true
      t.string  :target                       # 表示名 (自己PR / 案件1のプロジェクト名 など)
      t.string  :field                        # self_pr / specialties / skills / duties / project:<i>:title|description
      t.text    :issues                       # 指摘 (改行区切り)
      t.text    :suggestion                   # 改善版テキスト
      t.boolean :applied, null: false, default: false
      t.string  :source, null: false, default: "ai" # ai / manual
      t.integer :position, null: false, default: 0
      t.timestamps
    end
  end
end
