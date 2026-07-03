class AddYoutubeSelfPrToSkillSheets < ActiveRecord::Migration[8.0]
  def change
    # YouTube動画用のプロフィール/自己紹介(通常の自己PRとは別に切り替えて使う)
    add_column :skill_sheets, :youtube_self_pr, :text
  end
end
