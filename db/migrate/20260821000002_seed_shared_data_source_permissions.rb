# 既存の運用状態をそのまま権限テーブルへ写す。admin(西野)はレコード無しで全許可なので、
# 明示が要るのは今 外部ソースを使っている非admin だけ。今できていることを減らさないのが原則。
#   川村さん … Wing(Backlog) と リビング(Notion)
#   太田さん … テックリーダーズ(Trello) の閲覧と取込
# 外部サービスへの書き込みは「自分のキーで書いている人」だけに許可する。
# 借りたキーや ENV 共通のキーで書くと、外部側の履歴が貸し元名義になって誰の操作か追えなくなる。
class SeedSharedDataSourcePermissions < ActiveRecord::Migration[8.0]
  GRANTS = [
    { name_like: "%川村%", source_type: "backlog", can_write: :only_with_own_backlog_key },
    { name_like: "%川村%", source_type: "notion",  can_write: true },  # リビングのメモは従来どおり編集できる
    { name_like: "%太田%", source_type: "trello",  can_write: false }  # Trello キーは ENV 共通のため閲覧と取込まで
  ].freeze

  def up
    GRANTS.each do |grant|
      user = User.find_by("display_name LIKE ?", grant[:name_like])
      if user.nil?
        say("#{grant[:name_like]} に一致するユーザーが居ないのでスキップします")
        next
      end
      grant_permission(user, grant)
    end
  end

  def down
    GRANTS.each do |grant|
      user = User.find_by("display_name LIKE ?", grant[:name_like])
      UserDataSourcePermission.where(user_id: user.id, source_type: grant[:source_type]).delete_all if user
    end
  end

  private

  def grant_permission(user, grant)
    has_own_backlog_key = user.backlog_setting&.api_key.present?
    borrow_from = (grant[:source_type] == "backlog" && !has_own_backlog_key) ? admin_with_backlog_key : nil
    can_write = grant[:can_write] == :only_with_own_backlog_key ? has_own_backlog_key : grant[:can_write]

    UserDataSourcePermission.find_or_create_by!(user_id: user.id, source_type: grant[:source_type]) do |permission|
      permission.can_view = true
      permission.can_sync = true
      permission.can_write = can_write
      permission.credential_owner_id = borrow_from&.id
    end
    say("#{user.display_name}: #{grant[:source_type]} 閲覧/取込=可 書込=#{can_write} キー=#{borrow_from ? "#{borrow_from.display_name}から借用" : '自前'}")
  end

  # admin? は表示名/メール判定なので SQL では引けない。Backlog キーを持つ admin を Ruby 側で選ぶ。
  def admin_with_backlog_key
    User.joins(:backlog_setting)
        .where.not(backlog_settings: { api_key: [ nil, "" ] })
        .find(&:admin?)
  end
end
