# 再編集時に「文字なしのクリーン背景」を下敷きにできるよう、平坦化PNG(data)とは別に
# 背景だけのPNGを保存する。これが無い旧データは従来どおり data(文字込み)を背景に使う。
class AddCleanBackgroundToGeneratedThumbnails < ActiveRecord::Migration[8.0]
  def change
    add_column :generated_thumbnails, :clean_background, :binary
  end
end
