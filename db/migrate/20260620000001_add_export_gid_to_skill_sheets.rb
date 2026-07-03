class AddExportGidToSkillSheets < ActiveRecord::Migration[8.0]
  # 書き出し専用タブ(gid)。import が取り込み元タブの gid を保存するのとは別に、
  # 「書き出し先タブ」を固定したいスキルシート(例: 須崎さん専用テンプレ)のために持つ。
  # nil のときは従来どおり gid を書き出し先に使う。
  def change
    add_column :skill_sheets, :export_gid, :string
  end
end
