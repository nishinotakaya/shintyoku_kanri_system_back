class AddHoverToInterviewMindmapNodes < ActiveRecord::Migration[8.0]
  def change
    # リアルタイム共有ホバー: 誰がそのノードにカーソルを当てているか
    add_column :interview_mindmap_nodes, :hovered_by_user_id, :integer
    add_column :interview_mindmap_nodes, :hovered_at, :datetime
  end
end
