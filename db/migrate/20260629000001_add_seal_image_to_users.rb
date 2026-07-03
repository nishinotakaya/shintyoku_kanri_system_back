class AddSealImageToUsers < ActiveRecord::Migration[8.0]
  def change
    # 請求書/立替金/支払通知書PDFの印鑑(ハンコ)画像。data URL(base64) で保存。
    # 未設定なら従来の public/hanko_*.png/svg にフォールバックする。
    add_column :users, :seal_image, :text
  end
end
