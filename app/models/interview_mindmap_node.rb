class InterviewMindmapNode < ApplicationRecord
  belongs_to :interview_mindmap, inverse_of: :nodes
  belongs_to :parent, class_name: "InterviewMindmapNode", optional: true
  has_many :children, class_name: "InterviewMindmapNode", foreign_key: :parent_id, dependent: :destroy

  KINDS = %w[root question answer keyword followup].freeze

  def as_payload
    {
      id: id,
      parent_id: parent_id,
      kind: kind,
      text: text,
      position: position,
      checked: checked,
      expanded: expanded,
      source: source
    }
  end
end
