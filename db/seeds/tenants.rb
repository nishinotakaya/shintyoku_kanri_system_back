# テナント(会社)の初期データを投入する。
#   bin/rails runner db/seeds/tenants.rb
# 何度実行しても同じ状態になる(冪等)。ローカルと本番で user id が異なるため display_name で引く
# (id を直指定しない)。対象ユーザーが見つからない場合は警告だけ出して skip する(落とさない)。

def upsert_tenant(name:, code:, owner_display_name:, member_display_names: [])
  owner = User.find_by(display_name: owner_display_name)
  unless owner
    puts "警告: 代表ユーザー「#{owner_display_name}」が見つからないためテナント「#{name}」を skip します"
    return
  end

  tenant = Tenant.find_or_initialize_by(code: code)
  tenant.assign_attributes(name: name, owner_user: owner)
  tenant.save!

  member_display_names.each do |member_display_name|
    member = User.find_by(display_name: member_display_name)
    unless member
      puts "警告: メンバーユーザー「#{member_display_name}」が見つからないためテナント「#{name}」への追加を skip します"
      next
    end
    tenant.tenant_memberships.find_or_create_by!(user: member)
  end

  puts "テナント「#{tenant.name}」(#{tenant.code}) 代表=#{owner.display_name} メンバー=#{tenant.member_users.map(&:display_name)}"
end

upsert_tenant(name: "HAUKUR運送", code: "haukur", owner_display_name: "西野 雄太郎")
upsert_tenant(name: "プロアカ", code: "proaka", owner_display_name: "加藤 こうき", member_display_names: [ "岩切 弘道" ])
