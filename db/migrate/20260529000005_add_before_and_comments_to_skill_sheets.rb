class AddBeforeAndCommentsToSkillSheets < ActiveRecord::Migration[8.0]
  def change
    # 添削前 (Before) のスナップショット。AI 添削/生成の直前の構造化内容を JSON で保持。
    add_column :skill_sheets, :before_snapshot, :text

    # 閲覧権限のみ (スプレッドシートに書き戻せない) でもアプリ上でコメントを残せる。
    create_table :skill_sheet_comments do |t|
      t.integer :skill_sheet_id, null: false
      t.integer :author_user_id
      t.string  :author_name
      t.string  :target        # コメント対象 (例: 自己PR, 案件1)
      t.text    :body, null: false
      t.timestamps
    end
    add_index :skill_sheet_comments, :skill_sheet_id
  end
end
