class AddKanpeStyleToInterviewMindmaps < ActiveRecord::Migration[8.0]
  def change
    # カンペ生成スタイル: sales=西野式セールス / app_build=アプリを作る完全台本
    add_column :interview_mindmaps, :kanpe_style, :string, default: "sales", null: false
  end
end
