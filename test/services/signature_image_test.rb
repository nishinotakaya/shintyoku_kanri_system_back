require "test_helper"
require "base64"

# SignatureImage.validate!: 契約書の乙側電子署名(PNG data URI)の検証。
# data:image/png;base64, 限定 / デコード後300KB以下 / PNGマジックバイトの3点をカバーする。
class SignatureImageTest < Minitest::Test
  VALID_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=".freeze
  PNG_MAGIC_BYTES = "\x89PNG\r\n\x1a\n".b.freeze

  def test_valid_png_data_uri_returns_decoded_binary
    decoded = SignatureImage.validate!("data:image/png;base64,#{VALID_PNG_BASE64}")

    assert_equal Base64.strict_decode64(VALID_PNG_BASE64), decoded
    assert_equal PNG_MAGIC_BYTES, decoded.byteslice(0, PNG_MAGIC_BYTES.bytesize)
  end

  def test_blank_data_uri_is_rejected
    error_for_empty_string = assert_raises(SignatureImage::InvalidSignatureImage) { SignatureImage.validate!("") }
    assert_equal "署名画像がありません", error_for_empty_string.message

    error_for_nil = assert_raises(SignatureImage::InvalidSignatureImage) { SignatureImage.validate!(nil) }
    assert_equal "署名画像がありません", error_for_nil.message
  end

  def test_non_png_prefix_is_rejected
    error = assert_raises(SignatureImage::InvalidSignatureImage) do
      SignatureImage.validate!("data:image/jpeg;base64,#{VALID_PNG_BASE64}")
    end

    assert_equal "署名画像はPNG形式のみ対応しています", error.message
  end

  def test_invalid_base64_payload_is_rejected
    error = assert_raises(SignatureImage::InvalidSignatureImage) do
      SignatureImage.validate!("data:image/png;base64,not-valid-base64!!!")
    end

    assert_equal "署名画像のデータを読み取れません", error.message
  end

  def test_oversized_payload_is_rejected
    oversized_binary = PNG_MAGIC_BYTES + ("A" * (SignatureImage::MAX_BYTES + 1))
    data_uri = "data:image/png;base64,#{Base64.strict_encode64(oversized_binary)}"

    error = assert_raises(SignatureImage::InvalidSignatureImage) { SignatureImage.validate!(data_uri) }

    assert_equal "署名画像は300KB以下にしてください", error.message
  end

  # base64としては正しくデコードできるが、PNGのマジックバイトを持たないデータ。
  def test_payload_without_png_magic_bytes_is_rejected
    data_uri = "data:image/png;base64,#{Base64.strict_encode64('not a real png file body')}"

    error = assert_raises(SignatureImage::InvalidSignatureImage) { SignatureImage.validate!(data_uri) }

    assert_equal "署名画像のデータを読み取れません", error.message
  end
end
