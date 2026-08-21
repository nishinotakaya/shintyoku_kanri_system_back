# 進捗管理の外部データソース(Wing=backlog / リビング=notion / テックリーダーズ=trello)を
# 誰がどこまで扱えるかを1行で表す。レコードが無い＝不可(fail-closed)。admin だけは既定で全許可。
# credential_owner は API キーの貸し元。nil なら自分の設定を使う。
class UserDataSourcePermission < ApplicationRecord
  SOURCE_TYPES = %w[backlog notion trello].freeze
  SOURCE_LABELS = { "backlog" => "Wing(Backlog)", "notion" => "リビング(Notion)", "trello" => "テックリーダーズ(Trello)" }.freeze

  belongs_to :user
  belongs_to :credential_owner, class_name: "User", optional: true

  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :user_id, uniqueness: { scope: :source_type }
  validate :credential_owner_must_not_be_self
  validate :credential_owner_must_own_credentials

  def as_payload
    {
      source_type: source_type,
      can_view: can_view,
      can_sync: can_sync,
      can_write: can_write,
      credential_owner_id: credential_owner_id
    }
  end

  private

  def credential_owner_must_not_be_self
    return if credential_owner_id.nil? || credential_owner_id != user_id
    errors.add(:credential_owner_id, "は自分以外のユーザーを指定してください")
  end

  # 貸し元がさらに他人から借りていると参照が連鎖する(A→B→C)。貸し元は自前のキーを持つ人に限る。
  def credential_owner_must_own_credentials
    return if credential_owner_id.nil?
    borrowed = UserDataSourcePermission
      .where(user_id: credential_owner_id, source_type: source_type)
      .where.not(credential_owner_id: nil)
      .exists?
    errors.add(:credential_owner_id, "が他のユーザーからキーを借りているため指定できません") if borrowed
  end
end
