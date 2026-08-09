class AddFilmedToInterviewMindmaps < ActiveRecord::Migration[8.0]
  def change
    # 撮影済フラグ。YouTube用マインドマップの一覧で「全て/撮影済/撮影前」を絞り込むために使う
    add_column :interview_mindmaps, :filmed, :boolean, default: false, null: false
  end
end
