class AddSourceToInterviewMindmapNodes < ActiveRecord::Migration[8.0]
  def change
    # 由来: nil/ai=AI展開, manual=手入力(＋Q), bank=質問バンク取り込み
    add_column :interview_mindmap_nodes, :source, :string
  end
end
