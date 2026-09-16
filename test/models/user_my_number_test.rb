require "test_helper"

# User の個人番号(my_number)・生年月日(birth_date): 暗号化保存・正規化・検証・末尾4桁。
class UserMyNumberTest < Minitest::Test
  VALID_NUMBER = "123456789018".freeze

  def setup
    @user = User.create!(
      email: "my_number_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "個人番号テスト"
    )
  end

  def teardown
    @user.destroy
  end

  def test_my_number_is_normalized_before_save
    @user.update!(my_number: "１２３４-５６７８-９０１８")

    assert_equal VALID_NUMBER, @user.reload.my_number
  end

  def test_my_number_is_stored_encrypted
    @user.update!(my_number: VALID_NUMBER)

    stored_value = User.connection.select_value("SELECT my_number FROM users WHERE id = #{@user.id}")
    refute_includes stored_value.to_s, VALID_NUMBER, "個人番号が平文で保存されてはいけない"
    assert_equal VALID_NUMBER, User.find(@user.id).my_number
  end

  def test_my_number_with_wrong_check_digit_is_invalid
    @user.my_number = "123456789019"

    refute @user.valid?
    assert_includes @user.errors[:my_number].join, "チェックデジット"
  end

  def test_blank_my_number_clears_the_value
    @user.update!(my_number: VALID_NUMBER)
    @user.update!(my_number: "")

    assert_nil @user.reload.my_number
    assert_nil @user.my_number_last4
  end

  def test_my_number_last4_returns_only_trailing_digits
    @user.update!(my_number: VALID_NUMBER)

    assert_equal "9018", @user.my_number_last4
  end

  def test_birth_date_in_the_future_is_invalid
    @user.birth_date = Date.current + 1

    refute @user.valid?
    assert @user.errors[:birth_date].any?
  end

  def test_birth_date_in_the_past_is_valid
    @user.birth_date = Date.new(1990, 9, 30)

    assert @user.valid?
  end
end
