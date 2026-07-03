# ユーザーが勤怠アプリ内で作った HeyGen 資産。
# - voice        : 自分の声のクローン(voice_id)
# - photo_avatar : 自分の顔のトーキングフォト(talking_photo_id)
class HeygenAsset < ApplicationRecord
  belongs_to :user

  KINDS = %w[voice photo_avatar].freeze
  validates :kind, inclusion: { in: KINDS }

  scope :voices, -> { where(kind: "voice") }
  scope :photo_avatars, -> { where(kind: "photo_avatar") }

  def as_payload
    { id: id, kind: kind, ref_id: ref_id, name: name, status: status, preview_url: preview_url, created_at: created_at }
  end
end
