require "base64"

# 契約書の乙側電子署名として送られてくる PNG data URI の検証。
# data:image/png;base64, のみ許可 / デコード後 300KB 以下 / PNG マジックバイトを確認。
class SignatureImage
  class InvalidSignatureImage < StandardError; end

  DATA_URI_PREFIX = "data:image/png;base64,"
  MAX_BYTES = 300 * 1024
  PNG_MAGIC_BYTES = "\x89PNG\r\n\x1a\n".b

  # 検証済みならデコード後のバイナリを返す。違反時は InvalidSignatureImage を raise。
  def self.validate!(data_uri)
    raise InvalidSignatureImage, "署名画像がありません" if data_uri.blank?
    unless data_uri.start_with?(DATA_URI_PREFIX)
      raise InvalidSignatureImage, "署名画像はPNG形式のみ対応しています"
    end

    begin
      decoded = Base64.strict_decode64(data_uri.delete_prefix(DATA_URI_PREFIX))
    rescue ArgumentError
      raise InvalidSignatureImage, "署名画像のデータを読み取れません"
    end

    if decoded.bytesize > MAX_BYTES
      raise InvalidSignatureImage, "署名画像は300KB以下にしてください"
    end
    unless decoded.byteslice(0, PNG_MAGIC_BYTES.bytesize) == PNG_MAGIC_BYTES
      raise InvalidSignatureImage, "署名画像のデータを読み取れません"
    end

    decoded
  end
end
