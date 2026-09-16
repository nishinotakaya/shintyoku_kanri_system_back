require "test_helper"

# MyNumber: 個人番号(12桁)の正規化・チェックデジット検証・末尾4桁。
# 「123456789018」は上位11桁 12345678901 に対するチェックデジットが 8 になる例(手計算: Σ=212, 212 mod 11=3, 11-3=8)。
class MyNumberTest < Minitest::Test
  VALID_NUMBER = "123456789018".freeze

  def test_normalize_converts_fullwidth_digits_and_strips_separators
    assert_equal VALID_NUMBER, MyNumber.normalize("１２３４-５６７８-９０１８")
  end

  def test_normalize_returns_nil_for_blank_or_non_digit_input
    assert_nil MyNumber.normalize("")
    assert_nil MyNumber.normalize(nil)
    assert_nil MyNumber.normalize("番号なし")
  end

  def test_valid_accepts_number_with_matching_check_digit
    assert MyNumber.valid?(VALID_NUMBER)
  end

  def test_valid_rejects_number_with_wrong_check_digit
    refute MyNumber.valid?("123456789019")
  end

  def test_valid_rejects_wrong_length
    refute MyNumber.valid?("12345678901")
    refute MyNumber.valid?("1234567890188")
    refute MyNumber.valid?(nil)
  end

  # remainder が 0 か 1 のときはチェックデジット 0 になる分岐
  def test_valid_handles_zero_check_digit
    first_eleven = "00000000000"
    assert MyNumber.valid?("#{first_eleven}0")
  end

  def test_last4_returns_trailing_four_digits
    assert_equal "9018", MyNumber.last4(VALID_NUMBER)
    assert_nil MyNumber.last4(nil)
  end
end
