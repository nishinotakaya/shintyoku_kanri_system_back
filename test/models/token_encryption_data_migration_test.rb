require "test_helper"
require "active_record/migration"
require Rails.root.join("db/migrate/20261008100000_encrypt_external_tokens.rb")

# AC-03: 既存の平文行を暗号化するデータ移行。
class TokenEncryptionDataMigrationTest < Minitest::Test
  USER_COLUMNS = %w[
    openai_api_key google_access_token google_refresh_token wantedly_token
    anotherworks_token heygen_api_key canva_access_token canva_refresh_token
    trello_api_key trello_api_token
  ].freeze
  BACKLOG_COLUMNS = %w[backlog_password api_key session_cookie].freeze

  def setup
    @connection = User.connection
    @user = create_user("移行テスト")
    @other_user = create_user("移行テスト(他)")
    @created_backlog_setting_ids = []
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  def teardown
    ActiveRecord::Migration.verbose = @original_verbose
    BacklogSetting.where(id: @created_backlog_setting_ids).delete_all
    @user.destroy
    @other_user.destroy
  end

  def test_up_encrypts_every_user_column_and_keeps_readable_value
    plain_values = write_plaintext_user_columns(@user)

    run_migration_up

    USER_COLUMNS.each do |column|
      raw = raw_user_value(@user, column)
      refute_equal plain_values[column], raw, "#{column} が移行後も平文のまま"
      refute_includes raw.to_s, plain_values[column], "#{column} の生値に平文が含まれる"
      assert_equal plain_values[column], User.find(@user.id).public_send(column), "#{column} の復号結果が元の値と違う"
    end
  end

  def test_up_encrypts_every_backlog_setting_column_and_keeps_readable_value
    setting = create_backlog_setting(@user)
    plain_values = BACKLOG_COLUMNS.to_h { |column| [ column, "legacy-#{column}-#{SecureRandom.hex(6)}" ] }
    write_plaintext_backlog_columns(setting, plain_values)

    run_migration_up

    BACKLOG_COLUMNS.each do |column|
      raw = raw_backlog_value(setting, column)
      refute_equal plain_values[column], raw, "#{column} が移行後も平文のまま"
      refute_includes raw.to_s, plain_values[column], "#{column} の生値に平文が含まれる"
      assert_equal plain_values[column], BacklogSetting.find(setting.id).public_send(column), "#{column} の復号結果が元の値と違う"
    end
  end

  def test_up_is_idempotent
    user_values = write_plaintext_user_columns(@user)
    setting = create_backlog_setting(@user)
    backlog_values = BACKLOG_COLUMNS.to_h { |column| [ column, "legacy-#{column}-#{SecureRandom.hex(6)}" ] }
    write_plaintext_backlog_columns(setting, backlog_values)

    run_migration_up
    run_migration_up

    reloaded_user = User.find(@user.id)
    USER_COLUMNS.each do |column|
      assert_equal user_values[column], reloaded_user.public_send(column), "二重実行で #{column} が壊れた"
      refute_includes raw_user_value(@user, column).to_s, user_values[column], "二重実行後に #{column} が平文"
    end
    reloaded_setting = BacklogSetting.find(setting.id)
    BACKLOG_COLUMNS.each do |column|
      assert_equal backlog_values[column], reloaded_setting.public_send(column), "二重実行で #{column} が壊れた"
      refute_includes raw_backlog_value(setting, column).to_s, backlog_values[column], "二重実行後に #{column} が平文"
    end
  end

  def test_nil_columns_stay_nil_and_other_rows_are_not_corrupted
    @connection.execute("UPDATE users SET google_refresh_token = #{@connection.quote('only-this-one')} WHERE id = #{@user.id}")
    other_values = write_plaintext_user_columns(@other_user)
    setting_without_secrets = create_backlog_setting(@user)

    run_migration_up

    reloaded_user = User.find(@user.id)
    assert_equal "only-this-one", reloaded_user.google_refresh_token
    (USER_COLUMNS - %w[google_refresh_token]).each do |column|
      assert_nil raw_user_value(@user, column), "#{column} の nil が nil のままでない"
    end
    BACKLOG_COLUMNS.each do |column|
      assert_nil raw_backlog_value(setting_without_secrets, column), "backlog #{column} の nil が nil のままでない"
    end

    reloaded_other = User.find(@other_user.id)
    USER_COLUMNS.each do |column|
      assert_equal other_values[column], reloaded_other.public_send(column), "他ユーザーの #{column} が壊れた"
    end
  end

  private

  def create_user(display_name)
    User.create!(
      email: "mig_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: display_name
    )
  end

  def create_backlog_setting(user)
    setting = BacklogSetting.create!(user: user)
    @created_backlog_setting_ids << setting.id
    setting
  end

  def run_migration_up
    EncryptExternalTokens.new.up
  end

  def write_plaintext_user_columns(user)
    plain_values = USER_COLUMNS.to_h { |column| [ column, "legacy-#{column}-#{SecureRandom.hex(6)}" ] }
    assignments = plain_values.map { |column, value| "#{column} = #{@connection.quote(value)}" }.join(", ")
    @connection.execute("UPDATE users SET #{assignments} WHERE id = #{user.id}")
    plain_values
  end

  def write_plaintext_backlog_columns(setting, plain_values)
    assignments = plain_values.map { |column, value| "#{column} = #{@connection.quote(value)}" }.join(", ")
    @connection.execute("UPDATE backlog_settings SET #{assignments} WHERE id = #{setting.id}")
  end

  def raw_user_value(user, column)
    @connection.select_value("SELECT #{column} FROM users WHERE id = #{user.id}")
  end

  def raw_backlog_value(setting, column)
    @connection.select_value("SELECT #{column} FROM backlog_settings WHERE id = #{setting.id}")
  end
end
