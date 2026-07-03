class CreateSkillSheetTechs < ActiveRecord::Migration[8.0]
  def change
    # 技術スタックの 1 要素。案件のフリーテキスト(使用言語/DB/サーバOS/ツール)を
    # 正規化し、経験月数・最終使用を横断集計したもの。analyze_tech のたびに作り直す。
    create_table :skill_sheet_techs do |t|
      t.integer :skill_sheet_id, null: false
      t.string  :category                  # language / db / server_os / framework / tool
      t.string  :name                       # 正規化名 (例: Ruby on Rails, React)
      t.string  :version                    # メジャーのみ・任意 (例: 7, 19)。無ければ nil
      t.integer :months_used, default: 0    # 経験月数 (案件期間の合計)
      t.string  :last_used_on               # 最終使用 (例: 2026年5月 / 現在)
      t.integer :last_used_rank, default: 0 # 並び替え用に正規化した年月 (year*12+month)
      t.timestamps
    end
    add_index :skill_sheet_techs, %i[skill_sheet_id category]
  end
end
