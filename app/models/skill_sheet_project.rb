class SkillSheetProject < ApplicationRecord
  belongs_to :skill_sheet, inverse_of: :projects

  # 担当工程の bool マップ (例: {"要件定義"=>true, ...})。
  serialize :phases, coder: JSON, type: Hash

  # 見本シートの担当工程の並び順
  PHASE_KEYS = %w[要件定義 基本設計 詳細設計 実装・単体 結合テスト 総合テスト 保守・運用].freeze

  def as_payload
    {
      id: id,
      position: position,
      period_from: period_from,
      period_to: period_to,
      title: title,
      description: description,
      role_scale: role_scale,
      languages: languages,
      db: db,
      server_os: server_os,
      tools: tools,
      phases: phases.to_h,
      source: source,
      wantedly_work_experience_uuid: wantedly_work_experience_uuid,
      anotherworks_resume_id: anotherworks_resume_id
    }
  end
end
