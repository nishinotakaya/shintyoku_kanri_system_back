require "test_helper"

# MyNumberCardReader: OpenAI の応答(JSON)を個人番号・生年月日へ正規化する部分と、API キー未設定時の扱い。
# HTTP 呼び出し自体は行わない(normalize を直接検証する)。
class MyNumberCardReaderTest < Minitest::Test
  def reader
    MyNumberCardReader.new([ { bytes: "dummy", content_type: "image/jpeg" } ])
  end

  def test_normalize_returns_valid_number_and_iso_birth_date
    result = reader.send(:normalize, {
      "my_number" => "1234 5678 9018", "birth_date" => "1990-09-30",
      "name" => " 西野 鷹也 ", "address" => "千葉県松戸市", "confidence" => 93
    })

    assert_equal "123456789018", result[:my_number]
    assert result[:my_number_valid]
    assert_equal Date.new(1990, 9, 30), result[:birth_date]
    assert_equal "西野 鷹也", result[:name]
    assert_equal 93, result[:confidence]
  end

  def test_normalize_flags_wrong_check_digit
    result = reader.send(:normalize, { "my_number" => "123456789019" })

    assert_equal "123456789019", result[:my_number]
    refute result[:my_number_valid]
  end

  def test_normalize_handles_missing_or_unparseable_values
    result = reader.send(:normalize, { "my_number" => nil, "birth_date" => "平成2年9月30日", "confidence" => "高い" })

    assert_nil result[:my_number]
    refute result[:my_number_valid]
    assert_nil result[:birth_date]
    assert_equal 0, result[:confidence]
  end

  def test_call_returns_error_when_api_key_is_missing
    original_key = ENV.delete("OPENAI_API_KEY")
    begin
      result = MyNumberCardReader.call([ { bytes: "dummy", content_type: "image/jpeg" } ])
      assert_equal "OPENAI_API_KEY 未設定", result[:error]
    ensure
      ENV["OPENAI_API_KEY"] = original_key if original_key
    end
  end

  def test_call_returns_error_when_no_images_given
    original_key = ENV["OPENAI_API_KEY"]
    ENV["OPENAI_API_KEY"] = "test-key"
    begin
      result = MyNumberCardReader.call([])
      assert_equal "マイナンバーカードの画像を添付してください", result[:error]
    ensure
      original_key ? ENV["OPENAI_API_KEY"] = original_key : ENV.delete("OPENAI_API_KEY")
    end
  end
end
