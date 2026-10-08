# 既存の平文トークン/API キーを ActiveRecord::Encryption で暗号化し直すデータ移行。
# アプリ本体のモデル(コールバック/バリデーション)に依存しないよう最小モデルを定義する。
class EncryptExternalTokens < ActiveRecord::Migration[8.0]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
    encrypts :openai_api_key, :google_access_token, :google_refresh_token, :wantedly_token,
             :anotherworks_token, :heygen_api_key, :canva_access_token, :canva_refresh_token,
             :trello_api_key, :trello_api_token
  end

  class MigrationBacklogSetting < ActiveRecord::Base
    self.table_name = "backlog_settings"
    encrypts :backlog_password, :api_key, :session_cookie
  end

  USER_COLUMNS = %w[openai_api_key google_access_token google_refresh_token wantedly_token
                    anotherworks_token heygen_api_key canva_access_token canva_refresh_token
                    trello_api_key trello_api_token].freeze
  BACKLOG_COLUMNS = %w[backlog_password api_key session_cookie].freeze

  def up
    MigrationUser.reset_column_information
    MigrationBacklogSetting.reset_column_information
    encrypt_rows(MigrationUser, USER_COLUMNS)
    encrypt_rows(MigrationBacklogSetting, BACKLOG_COLUMNS)
  end

  # 運用注意: 適用後に旧コード(encrypts 宣言なし)へ戻すと暗号文をそのままトークンとして使い、
  # 外部連携が全滅する。戻すときはコードを戻さず support_unencrypted_data を維持したまま前進修正する。
  # 暗号化キー(credentials の active_record_encryption)を失うと復旧不能。
  # Fly ボリュームの旧スナップショットには平文が残る点にも留意する。
  # 平文に戻すと流出リスクが復活するため元に戻さない。
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # 値のある列を読み(平文/暗号文どちらも可)、そのまま書き戻して暗号文にする。
  # 既に暗号化済みの行は復号→再暗号化されるだけなので再実行しても壊れない。
  def encrypt_rows(model, columns)
    model.find_each do |record|
      present_columns = columns.select { |column| record.public_send(column).present? }
      next if present_columns.empty?

      present_columns.each { |column| record.public_send(:"#{column}=", record.public_send(column)) }
      present_columns.each { |column| record.public_send(:"#{column}_will_change!") }
      record.save!(validate: false)
    end
  end
end
