class CreateSkillSheets < ActiveRecord::Migration[8.0]
  def change
    create_table :skill_sheets do |t|
      t.integer :user_id, null: false
      t.string  :spreadsheet_url
      t.string  :spreadsheet_id
      t.string  :gid
      # 上部ブロック
      t.string  :engineer_name
      t.string  :age
      t.string  :gender
      t.string  :address
      t.string  :start_date
      t.string  :nearest_station
      t.text    :specialties   # 得意分野
      t.text    :skills        # 得意技術
      t.text    :duties        # 得意業務
      t.text    :self_pr
      # キャッシュ / AI 結果
      t.text     :raw_content   # 読み取った CSV の生キャッシュ
      t.text     :review_result # AI 添削結果 (JSON)
      t.datetime :reviewed_at
      t.datetime :synced_at
      t.timestamps
    end
    add_index :skill_sheets, :user_id
  end
end
