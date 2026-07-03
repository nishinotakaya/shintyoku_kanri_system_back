# HeyGen で生成する「本人が喋るインタビュー動画」1本ぶんの状態。
# script(台本) と subtitles(テロップ JSON) を保持し、システムから編集できる。
class InterviewVideo < ApplicationRecord
  belongs_to :user
  belongs_to :interview_mindmap, optional: true

  STATUSES = %w[draft processing completed failed].freeze

  validates :status, inclusion: { in: STATUSES }

  # subtitles は JSON 文字列で保存。配列(ハッシュ)で読み書きする。
  def subtitle_list
    JSON.parse(subtitles.presence || "[]")
  rescue JSON::ParserError
    []
  end

  def subtitle_list=(arr)
    self.subtitles = Array(arr).to_json
  end

  def as_payload
    {
      id: id,
      user_id: user_id,
      interview_mindmap_id: interview_mindmap_id,
      title: title,
      script: script,
      script_kana: script_kana,
      subtitles: subtitle_list,
      avatar_kind: avatar_kind,
      avatar_id: avatar_id,
      talking_photo_id: talking_photo_id,
      photo_url: photo_url,
      voice_id: voice_id,
      status: status,
      video_url: video_url,
      duration: duration,
      error: error,
      created_at: created_at
    }
  end
end
