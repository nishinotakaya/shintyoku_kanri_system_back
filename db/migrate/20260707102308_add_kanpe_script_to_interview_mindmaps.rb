class AddKanpeScriptToInterviewMindmaps < ActiveRecord::Migration[8.0]
  def change
    add_column :interview_mindmaps, :kanpe_script, :text
  end
end
