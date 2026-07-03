class AddCanvaAndThumbnails < ActiveRecord::Migration[8.0]
  def change
    # Canva Connect API の OAuth トークン(ユーザー個別)。Google 連携列と同じ平文方式に揃える。
    add_column :users, :canva_access_token, :text
    add_column :users, :canva_refresh_token, :text
    add_column :users, :canva_token_expires_at, :datetime
    # OAuth(PKCE)の途中状態。connect時に保存し、callback(無認証)でstate照合してユーザー特定する。
    add_column :users, :canva_oauth_state, :string
    add_column :users, :canva_oauth_verifier, :string
    add_index  :users, :canva_oauth_state

    # 生成したサムネイル(背景PNG or Canva書き出しPNG)を履歴として保存する。
    # data は BLOB(既存の file_data と同じ t.binary 方式)。
    create_table :generated_thumbnails do |t|
      t.references :user, null: false, foreign_key: true
      t.references :interview_mindmap, null: true, foreign_key: true

      t.string  :title,           null: false, default: ""
      t.text    :prompt                              # gpt-image-1 に渡した背景プロンプト
      t.text    :copy_json                           # {main_copy, highlight_word, sub_copy} を JSON 文字列で
      t.string  :source,          null: false, default: "gpt_image" # gpt_image / canva
      t.string  :canva_design_id                     # Canva 上のデザインID
      t.string  :canva_edit_url                      # Canva エディタの編集URL

      t.string  :content_type,    null: false, default: "image/png"
      t.integer :byte_size,       null: false, default: 0
      t.binary  :data                                # PNG バイナリ

      t.timestamps
    end
  end
end
