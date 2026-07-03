require "digest"
require "securerandom"

# 請求書・支払通知書の電子証明(レベルA)を発行する。
# payload(証明する内容)を正規化して SHA256 を取り、署名者・日時とともに証跡を残す。
class InvoiceCertifier
  # target_type/target_id: 証明対象 / kind: "application" | "payment_proof"
  # payload: 証明する内容のハッシュ(金額・宛先・日付・明細など)
  def self.certify(target_type:, target_id:, kind:, user:, payload:)
    InvoiceCertification.create!(
      target_type: target_type,
      target_id: target_id,
      kind: kind,
      user: user,
      content_sha256: Digest::SHA256.hexdigest(normalize(payload)),
      signed_at: Time.current,
      verify_token: SecureRandom.hex(16),
      payload_snapshot: payload.to_json
    )
  end

  # 検証: 現在の内容を再ハッシュして証跡と一致するか
  def self.verify(token, current_payload: nil)
    cert = InvoiceCertification.find_by(verify_token: token)
    return nil unless cert
    result = cert.as_payload
    if current_payload
      now = Digest::SHA256.hexdigest(normalize(current_payload))
      result = result.merge(tampered: now != cert.content_sha256)
    end
    result
  end

  # キーをソートして安定した文字列にする(表示順でハッシュが変わらないように)
  def self.normalize(payload)
    deep_sort(payload).to_json
  end

  def self.deep_sort(obj)
    case obj
    when Hash then obj.sort_by { |k, _| k.to_s }.to_h { |k, v| [ k.to_s, deep_sort(v) ] }
    when Array then obj.map { |v| deep_sort(v) }
    else obj
    end
  end
end
