require "test_helper"

# User.admin_first: 統合帳票(請求書/立替金)の「主体」を決める並び替え。
# 先頭ユーザーが差出人ブロック・印鑑・振込先になるため、admin(西野) が必ず先頭に来ること。
# 回帰: メール添付だけ並び替えが抜けていて、統合立替金に川村さんのハンコが押されていた。
class UserAdminFirstTest < Minitest::Test
  def setup
    @admin = User.create!(email: "admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @member = User.create!(email: "member_#{SecureRandom.hex(4)}@example.com",
                           password: "password123", display_name: "川村 卓也", closing_day: 25)
  end

  def teardown
    [ @admin, @member ].compact.each { |user| InvoiceSetting.where(user_id: user.id).delete_all; user.destroy }
  end

  def test_admin_comes_first_even_when_listed_last
    assert_equal [ @admin, @member ], User.admin_first([ @member, @admin ])
  end

  def test_keeps_order_when_admin_already_first
    assert_equal [ @admin, @member ], User.admin_first([ @admin, @member ])
  end

  def test_removes_duplicates
    assert_equal [ @admin, @member ], User.admin_first([ @member, @admin, @member, @admin ])
  end

  def test_without_admin_keeps_given_order
    other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "須崎 彩", closing_day: 25)
    assert_equal [ @member, other ], User.admin_first([ @member, other ])
  ensure
    InvoiceSetting.where(user_id: other.id).delete_all
    other&.destroy
  end
end
