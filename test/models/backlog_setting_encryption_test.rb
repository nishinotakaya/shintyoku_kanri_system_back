require "test_helper"

# AC-03: BacklogSetting の認証情報列は非決定的 encrypts で保存される。
class BacklogSettingEncryptionTest < Minitest::Test
  ENCRYPTED_COLUMNS = %i[backlog_password api_key session_cookie].freeze

  def setup
    @user = User.create!(
      email: "bl_enc_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "Backlog暗号化テスト"
    )
    @setting = BacklogSetting.create!(user: @user)
  end

  def teardown
    @setting.destroy
    @user.destroy
  end

  def raw_value(column)
    BacklogSetting.connection.select_value("SELECT #{column} FROM backlog_settings WHERE id = #{@setting.id}")
  end

  def test_columns_are_declared_encrypted
    ENCRYPTED_COLUMNS.each do |column|
      assert_includes BacklogSetting.encrypted_attributes.to_a.map(&:to_sym), column, "#{column} が encrypts 宣言されていない"
    end
  end

  def test_value_is_not_stored_as_plaintext
    ENCRYPTED_COLUMNS.each do |column|
      plain = "secret-#{column}-#{SecureRandom.hex(6)}"
      @setting.update!(column => plain)

      refute_includes raw_value(column).to_s, plain, "#{column} が平文で DB に保存されている"
    end
  end

  def test_value_round_trips_after_reload
    ENCRYPTED_COLUMNS.each do |column|
      plain = "secret-#{column}-#{SecureRandom.hex(6)}"
      @setting.update!(column => plain)

      assert_equal plain, BacklogSetting.find(@setting.id).public_send(column), "#{column} の復号結果が元の値と違う"
    end
  end

  def test_plaintext_row_written_directly_is_still_readable
    ENCRYPTED_COLUMNS.each do |column|
      plain = "legacy-#{column}-#{SecureRandom.hex(6)}"
      quoted = BacklogSetting.connection.quote(plain)
      BacklogSetting.connection.execute("UPDATE backlog_settings SET #{column} = #{quoted} WHERE id = #{@setting.id}")

      assert_equal plain, BacklogSetting.find(@setting.id).public_send(column), "#{column} の平文行が読めない(support_unencrypted_data)"
    end
  end
end
