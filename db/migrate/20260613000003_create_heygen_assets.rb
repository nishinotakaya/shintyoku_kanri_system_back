class CreateHeygenAssets < ActiveRecord::Migration[8.0]
  def change
    create_table :heygen_assets do |t|
      t.integer :user_id, null: false
      t.string  :kind, null: false          # "voice"(クローン音声) | "photo_avatar"(自分の顔)
      t.string  :ref_id, null: false        # HeyGen の voice_id / talking_photo_id
      t.string  :name
      t.string  :status, null: false, default: "ready" # ready | processing | failed
      t.string  :preview_url                # 顔写真のプレビュー等
      t.timestamps
    end
    add_index :heygen_assets, [ :user_id, :kind ]
  end
end
