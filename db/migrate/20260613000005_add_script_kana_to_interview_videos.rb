class AddScriptKanaToInterviewVideos < ActiveRecord::Migration[8.0]
  def change
    # 読み仮名(ひらがな)台本。HeyGen TTS が漢字を誤読しないよう、読み上げにはこちらを使う。
    add_column :interview_videos, :script_kana, :text
  end
end
