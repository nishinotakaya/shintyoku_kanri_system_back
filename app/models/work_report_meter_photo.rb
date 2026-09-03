# 稼働報告書(運送)のメーター写真。開始/終了メーターの値は写真をAI読取して入力する運用で、
# 撮影した写真そのものを日報に紐づけて保存する(検印者が後から突き合わせられるように)。
# 一覧APIで写真バイナリを読み込まないよう work_reports 本体とはテーブルを分けている。
class WorkReportMeterPhoto < ApplicationRecord
  KINDS = %w[start end].freeze
  # 配信は disposition: inline なので、HTML等を仕込んだ stored XSS を防ぐため画像タイプのみ許可
  ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze

  belongs_to :work_report

  validates :kind, presence: true, inclusion: { in: KINDS }, uniqueness: { scope: :work_report_id }
end
