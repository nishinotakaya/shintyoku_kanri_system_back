# バックログ/GitHub/freee タブの表示を feature_flags(settings_backlog / settings_github / settings_freee) で
# 制御するようにするための移行。既に認証情報を保存済みの一般ユーザーがタブを失わないよう、
# 該当する設定レコードを持つユーザーには ON を明示的に書き込む。
# admin はキーが無ければ ON 扱い(User#can_use?)なので、明示が要るのは一般ユーザーだが、
# admin に ON を書き込んでも害は無いため全ユーザーを対象にする。
class BackfillIntegrationSettingsFeatureFlags < ActiveRecord::Migration[8.0]
  # フラグキー => そのキーが守る設定を保存しているテーブル
  INTEGRATION_SETTING_TABLES = {
    "settings_backlog" => "backlog_settings",
    "settings_github" => "github_settings",
    "settings_freee" => "freee_connections"
  }.freeze

  def up
    user_ids_by_flag = INTEGRATION_SETTING_TABLES.transform_values do |table_name|
      select_values("SELECT DISTINCT user_id FROM #{table_name}").to_set
    end

    User.find_each do |user|
      feature_flags = user.feature_flags.to_h
      flags_to_add = user_ids_by_flag.each_with_object({}) do |(flag_key, user_ids), flags|
        next if feature_flags.key?(flag_key)
        flags[flag_key] = true if user_ids.include?(user.id)
      end
      next if flags_to_add.empty?

      user.update_column(:feature_flags, feature_flags.merge(flags_to_add))
      say("#{user.display_name}: #{flags_to_add.keys.join(', ')} を ON に引き継ぎ")
    end
  end

  def down
    # feature_flags への追記のみで既存キーを上書きしないため、巻き戻しは行わない。
  end
end
