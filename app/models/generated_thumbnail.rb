# interview-mindmap(YouTubeモード)から生成した動画サムネイル。
# - source = "gpt_image" : gpt-image-1 で生成した背景PNG(フロントCanvasで文字合成して保存し直すこともある)
# - source = "canva"     : Canva で仕上げて書き出したPNG
class GeneratedThumbnail < ApplicationRecord
  belongs_to :user
  belongs_to :interview_mindmap, optional: true

  SOURCES = %w[gpt_image canva].freeze
  validates :source, inclusion: { in: SOURCES }

  scope :recent, -> { order(created_at: :desc) }

  # コピー(main_copy/highlight_word/sub_copy)は JSON 文字列で持つ。
  def copy
    JSON.parse(copy_json.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  def copy=(hash)
    self.copy_json = (hash || {}).to_json
  end

  # 画像バイナリを除いた一覧用 JSON。data は別エンドポイントでバイナリ配信する。
  def as_payload
    {
      id: id,
      title: title,
      source: source,
      prompt: prompt,
      copy: copy,
      canva_design_id: canva_design_id,
      canva_edit_url: canva_edit_url,
      content_type: content_type,
      byte_size: byte_size,
      image_url: "/api/v1/thumbnails/#{id}/image",
      # 再編集用：文字なしのクリーン背景があればそのURL（無ければ image_url を下敷きに＝旧挙動）
      has_clean_background: clean_background.present?,
      clean_background_url: clean_background.present? ? "/api/v1/thumbnails/#{id}/clean_background" : nil,
      created_at: created_at
    }
  end
end
