class CreateWbsExcelTemplates < ActiveRecord::Migration[8.0]
  # Notion(WBS) を受領Excel「プロジェクトのスケジュール」形式で書き出すためのテンプレート原本。
  # ユーザー横断の共有データなので全体で1件のみ保持する(登録時に既存行を置き換える)。
  def change
    create_table :wbs_excel_templates do |t|
      t.string   :file_name, null: false
      t.binary   :content, null: false
      t.integer  :uploaded_by_user_id, null: false
      t.datetime :uploaded_at, null: false
      t.timestamps
    end
  end
end
