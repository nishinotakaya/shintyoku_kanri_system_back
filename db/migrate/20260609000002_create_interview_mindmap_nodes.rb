class CreateInterviewMindmapNodes < ActiveRecord::Migration[8.0]
  def change
    create_table :interview_mindmap_nodes do |t|
      t.integer :interview_mindmap_id, null: false
      t.integer :parent_id                    # 自己参照(null=root)
      t.string  :kind, null: false, default: "question" # root/question/answer/keyword/followup
      t.text    :text
      t.integer :position, default: 0
      t.boolean :checked, default: false, null: false
      t.boolean :expanded, default: false, null: false
      t.timestamps
    end
    add_index :interview_mindmap_nodes, [ :interview_mindmap_id, :parent_id, :position ], name: "idx_imnodes_tree"
  end
end
