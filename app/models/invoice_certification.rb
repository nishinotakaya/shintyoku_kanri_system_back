# 請求書・支払通知書の電子証明(レベルA: 操作者・日時・内容ハッシュの証跡)。
# 追記のみ(更新・削除しない)。verify_token で公開検証する。
class InvoiceCertification < ApplicationRecord
  belongs_to :user

  KINDS = %w[application payment_proof].freeze
  validates :kind, inclusion: { in: KINDS }
  validates :verify_token, presence: true, uniqueness: true

  def snapshot
    JSON.parse(payload_snapshot.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  def kind_label
    { "application" => "請求書 申請", "payment_proof" => "振込確認証 / 支払通知" }[kind] || kind
  end

  def as_payload
    {
      id: id, target_type: target_type, target_id: target_id, kind: kind, kind_label: kind_label,
      signer: user&.display_name, signer_id: user_id,
      signed_at: signed_at, content_sha256: content_sha256, verify_token: verify_token,
      verify_id: content_sha256.to_s.first(12)
    }
  end
end
