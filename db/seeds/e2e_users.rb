# E2E(e2e/data_source_permissions.spec.ts)用のアカウントを作る。開発環境専用。
#   bin/rails runner db/seeds/e2e_users.rb
# 実ユーザーの権限やフラグを触らずに権限の効き方だけを検証したいので、専用ユーザーを用意する。
# 何度実行しても同じ状態になる(冪等)。
abort("開発環境でのみ実行してください (現在: #{Rails.env})") unless Rails.env.development?

SCREEN_FLAGS = { "attendance" => true, "progress" => true }.freeze

def upsert_e2e_user(email:, display_name:)
  user = User.find_or_initialize_by(email: email)
  user.assign_attributes(password: "password", display_name: display_name, closing_day: 25)
  user.feature_flags = user.feature_flags.to_h.merge(SCREEN_FLAGS)
  user.calendar_persons = [] # 既定(西野川村は全員/それ以外は本人)に戻してから流す
  user.save!
  ProgressWorkspace.ensure_defaults!(user)
  user
end

# display_name に「西野」を含むと User#admin? が true になる(名前判定)
admin = upsert_e2e_user(email: "e2e_admin@example.com", display_name: "西野 E2E")

# 川村さんと同じ権限構成(Wing+リビングのみ、Backlog キーは admin から借用、外部書き込み不可)
member = upsert_e2e_user(email: "e2e_member@example.com", display_name: "E2E 共有メンバー")
member.user_data_source_permissions.find_or_create_by!(source_type: "backlog") do |permission|
  permission.can_view = true
  permission.can_sync = true
  permission.can_write = false
  permission.credential_owner_id = admin.id
end
member.user_data_source_permissions.find_or_create_by!(source_type: "notion") do |permission|
  permission.can_view = true
  permission.can_sync = true
  permission.can_write = true
end

# 権限レコードを1件も持たない第三者。何も見えないことの確認用。
outsider = upsert_e2e_user(email: "e2e_outsider@example.com", display_name: "岩切 太郎(E2E)")

[ admin, member, outsider ].each do |user|
  puts "#{user.display_name}: admin?=#{user.admin?} 閲覧可=#{user.viewable_data_source_types.inspect}"
end
