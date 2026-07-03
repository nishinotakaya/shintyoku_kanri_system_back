class AddTemplateTypeToSkillSheets < ActiveRecord::Migration[8.0]
  # スキルシートのテンプレ種別。"engineer"(既定=従来のエンジニア用レイアウト) /
  # "creator"(デザイン・クリエイター用テンプレに値だけ流し込む) を切り替える。
  # 須崎さんのような動画編集者は "creator"。
  def change
    add_column :skill_sheets, :template_type, :string, default: "engineer", null: false
  end
end
