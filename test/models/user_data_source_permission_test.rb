require "test_helper"

# 進捗データソースの権限は「レコードが無ければ不可(fail-closed)」。admin だけは既定で全許可。
# Backlog は認証情報だけを貸し元から借り、担当者フィルタ等の個人設定は自分のものを使う。
class UserDataSourcePermissionTest < ActiveSupport::TestCase
  def setup
    @admin = User.create!(email: "admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @member = User.create!(email: "member_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "川村 卓也", closing_day: 25)
    @admin.create_backlog_setting!(backlog_url: "https://admin.backlog.jp", backlog_email: "admin@example.com",
                                   api_key: "ADMIN_KEY", board_id: 11)
  end

  def teardown
    [ @admin, @member ].compact.each(&:destroy)
  end

  def test_権限レコードが無い一般ユーザーは全てのデータソースを扱えない
    assert_not @member.can_view_data_source?("backlog")
    assert_not @member.can_sync_data_source?("notion")
    assert_not @member.can_write_data_source?("trello")
    assert_empty @member.viewable_data_source_types
  end

  def test_管理者は権限レコードが無くても全てのデータソースを扱える
    assert @admin.can_view_data_source?("trello")
    assert @admin.can_sync_data_source?("trello")
    assert @admin.can_write_data_source?("trello")
    assert_equal UserDataSourcePermission::SOURCE_TYPES.sort, @admin.viewable_data_source_types.sort
  end

  def test_閲覧のみ許可されたユーザーは同期も書き込みもできない
    @member.user_data_source_permissions.create!(source_type: "notion", can_view: true)

    assert @member.can_view_data_source?("notion")
    assert_not @member.can_sync_data_source?("notion")
    assert_not @member.can_write_data_source?("notion")
    assert_equal [ "notion" ], @member.viewable_data_source_types
  end

  def test_貸し元を指定すると認証情報だけが借りたものになる
    @member.create_backlog_setting!(backlog_url: "https://member.backlog.jp", backlog_email: "member@example.com",
                                    api_key: "MEMBER_KEY", board_id: 22, assignee_name_filter: "川村")
    @member.user_data_source_permissions.create!(source_type: "backlog", can_view: true, can_sync: true,
                                                 credential_owner_id: @admin.id)

    borrowed = @member.reload.backlog_connection_setting

    assert_equal "ADMIN_KEY", borrowed.api_key, "API キーは貸し元のもの"
    assert_equal "https://admin.backlog.jp", borrowed.backlog_url
    assert_equal 11, borrowed.board_id
    assert_equal "川村", borrowed.assignee_name_filter, "担当者フィルタは自分の設定のまま"
  end

  def test_借用しても貸し元の設定は書き換わらない
    @member.user_data_source_permissions.create!(source_type: "backlog", can_view: true,
                                                 credential_owner_id: @admin.id)

    borrowed = @member.reload.backlog_connection_setting
    borrowed.api_key = "OVERWRITTEN"

    assert_equal "ADMIN_KEY", @admin.reload.backlog_setting.api_key
  end

  def test_貸し元のキーが空なら自分の設定にフォールバックする
    @admin.backlog_setting.update!(api_key: "")
    @member.create_backlog_setting!(backlog_url: "https://member.backlog.jp", api_key: "MEMBER_KEY", board_id: 22)
    @member.user_data_source_permissions.create!(source_type: "backlog", can_view: true, can_sync: true,
                                                 credential_owner_id: @admin.id)

    setting = @member.reload.backlog_connection_setting

    assert_equal "MEMBER_KEY", setting.api_key, "貸し元の設定漏れで同期が止まらないこと"
    assert_equal 22, setting.board_id
  end

  def test_貸し元の指定が無ければ自分の設定を使う
    @member.create_backlog_setting!(backlog_url: "https://member.backlog.jp", api_key: "MEMBER_KEY", board_id: 22)

    assert_equal "MEMBER_KEY", @member.reload.backlog_connection_setting.api_key
  end

  def test_自分自身を貸し元にはできない
    permission = @member.user_data_source_permissions.build(source_type: "backlog", can_view: true,
                                                            credential_owner_id: @member.id)

    assert_not permission.valid?
    assert_includes permission.errors[:credential_owner_id].join, "自分以外"
  end

  def test_他人から借りている人を貸し元にはできない
    third = User.create!(email: "third_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "岩切 太郎", closing_day: 25)
    @member.user_data_source_permissions.create!(source_type: "backlog", can_view: true,
                                                 credential_owner_id: @admin.id)

    chained = third.user_data_source_permissions.build(source_type: "backlog", can_view: true,
                                                       credential_owner_id: @member.id)

    assert_not chained.valid?, "借り元の連鎖(A→B→C)は禁止"
  ensure
    third&.destroy
  end

  def test_同じソースの権限は1ユーザー1件まで
    @member.user_data_source_permissions.create!(source_type: "notion", can_view: true)
    duplicated = @member.user_data_source_permissions.build(source_type: "notion", can_view: false)

    assert_not duplicated.valid?
  end
end
