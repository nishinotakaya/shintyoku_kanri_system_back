# 稼働報告書(運送)の実費レシート写真。高速代・駐車場代などの領収書を1日報に複数枚添付できる。
# amount/label は AI 読取結果(手修正可)。合計は transit_fee(高速代・駐車場代など実費)の自動入力に使う。
# 一覧APIで写真バイナリを読み込まないよう work_reports 本体とはテーブルを分けている。
class WorkReportExpensePhoto < ApplicationRecord
  # 配信は disposition: inline なので、HTML等を仕込んだ stored XSS を防ぐため画像タイプのみ許可
  ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze

  belongs_to :work_report

  validates :amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
end
