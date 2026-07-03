class CreateInterviewVideos < ActiveRecord::Migration[8.0]
  def change
    create_table :interview_videos do |t|
      t.integer :user_id, null: false                 # 対象者(誰の動画か)
      t.integer :interview_mindmap_id                  # 元になったマインドマップ(任意)
      t.string  :title
      t.text    :script                                # 喋らせる本文
      t.text    :subtitles                             # テロップ(JSON配列: [{text, emphasis, start, end}])
      t.string  :avatar_kind, default: "avatar"        # "avatar"(ストック) | "talking_photo"(写真)
      t.string  :avatar_id                             # ストックアバターID
      t.string  :talking_photo_id                      # 写真アバターID(アップロード後)
      t.string  :photo_url                             # アップロードした写真のプレビューURL
      t.string  :voice_id                              # HeyGen ボイスID
      t.string  :heygen_video_id                       # HeyGen 側の video_id
      t.string  :status, null: false, default: "draft" # draft|processing|completed|failed
      t.text    :video_url                             # 完成動画URL(署名付き・期限あり)
      t.float   :duration                              # 秒数
      t.text    :error                                 # 失敗理由
      t.timestamps
    end
    add_index :interview_videos, :user_id
    add_index :interview_videos, :interview_mindmap_id
  end
end
