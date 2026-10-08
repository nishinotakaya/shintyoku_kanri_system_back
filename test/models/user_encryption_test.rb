require "test_helper"

# AC-03: User の外部トークン列は非決定的 encrypts で保存される。
# 既存の平文行は support_unencrypted_data で引き続き読める。
class UserEncryptionTest < Minitest::Test
  ENCRYPTED_COLUMNS = %i[
    openai_api_key google_access_token google_refresh_token wantedly_token
    anotherworks_token heygen_api_key canva_access_token canva_refresh_token
    trello_api_key trello_api_token
  ].freeze

  def setup
    @user = User.create!(
      email: "enc_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "暗号化テスト"
    )
  end

  def teardown
    @user.destroy
  end

  def raw_value(column)
    User.connection.select_value("SELECT #{column} FROM users WHERE id = #{@user.id}")
  end

  def test_columns_are_declared_encrypted
    ENCRYPTED_COLUMNS.each do |column|
      assert_includes User.encrypted_attributes.to_a.map(&:to_sym), column, "#{column} が encrypts 宣言されていない"
    end
  end

  def test_value_is_not_stored_as_plaintext
    ENCRYPTED_COLUMNS.each do |column|
      plain = "secret-#{column}-#{SecureRandom.hex(6)}"
      @user.update!(column => plain)

      refute_includes raw_value(column).to_s, plain, "#{column} が平文で DB に保存されている"
    end
  end

  def test_value_round_trips_after_reload
    ENCRYPTED_COLUMNS.each do |column|
      plain = "secret-#{column}-#{SecureRandom.hex(6)}"
      @user.update!(column => plain)

      assert_equal plain, User.find(@user.id).public_send(column), "#{column} の復号結果が元の値と違う"
    end
  end

  def test_plaintext_row_written_directly_is_still_readable
    ENCRYPTED_COLUMNS.each do |column|
      plain = "legacy-#{column}-#{SecureRandom.hex(6)}"
      quoted = User.connection.quote(plain)
      User.connection.execute("UPDATE users SET #{column} = #{quoted} WHERE id = #{@user.id}")

      assert_equal plain, User.find(@user.id).public_send(column), "#{column} の平文行が読めない(support_unencrypted_data)"
    end
  end

  def test_nil_and_blank_values_are_preserved
    ENCRYPTED_COLUMNS.each do |column|
      @user.update!(column => nil)
      assert_nil User.find(@user.id).public_send(column), "#{column} の nil が保たれない"

      @user.update!(column => "")
      reloaded_value = User.find(@user.id).public_send(column)
      assert_equal "", reloaded_value, "#{column} の空文字が保たれない"
      refute reloaded_value.present?, "#{column} の空文字が present? になる"
    end
  end

  def test_same_plaintext_encrypts_non_deterministically
    @user.update!(google_refresh_token: "same-token")
    first_raw = raw_value(:google_refresh_token)
    @user.update!(google_refresh_token: nil)
    @user.update!(google_refresh_token: "same-token")

    refute_equal first_raw, raw_value(:google_refresh_token), "暗号文が決定的になっている(非決定的であるべき)"
  end
end
