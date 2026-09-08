# Notion(WBS) を受領Excel「プロジェクトのスケジュール」形式で書き出すためのテンプレート原本。
# ユーザー横断の共有データなので、常に最新の1件だけを保持する(登録時に既存行を置き換える)。
class WbsExcelTemplate < ApplicationRecord
  MAX_CONTENT_BYTES = 20.megabytes

  belongs_to :uploaded_by_user, class_name: "User"

  validates :file_name, presence: true
  validates :content, presence: true
  validate :content_size_within_limit

  # 既存のテンプレートを置き換えて新しいテンプレートを1件だけ登録する。
  def self.replace!(file_name:, content:, uploaded_by_user:)
    transaction do
      delete_all
      create!(
        file_name: file_name,
        content: content,
        uploaded_by_user: uploaded_by_user,
        uploaded_at: Time.current
      )
    end
  end

  # 現在登録されている唯一のテンプレート。
  def self.current
    order(:id).last
  end

  # 「プロジェクトのスケジュール」シートのヘッダ情報(プロジェクト名/会社名/開始日)。読めない場合は各nil。
  def schedule_header
    WbsScheduleHeaderReader.new(content).call
  end

  private

  def content_size_within_limit
    return if content.blank?
    errors.add(:content, "は #{MAX_CONTENT_BYTES / 1.megabyte}MB 以下にしてください") if content.bytesize > MAX_CONTENT_BYTES
  end
end
