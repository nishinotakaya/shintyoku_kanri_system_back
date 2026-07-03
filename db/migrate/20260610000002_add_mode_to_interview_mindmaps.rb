class AddModeToInterviewMindmaps < ActiveRecord::Migration[8.0]
  def change
    # interview=面談対策 / youtube=YouTubeインタビュー動画
    add_column :interview_mindmaps, :mode, :string, null: false, default: "interview"
  end
end
