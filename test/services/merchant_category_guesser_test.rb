require "test_helper"

# MerchantCategoryGuesser: カード明細の摘要から勘定科目を推定する。
# 実際の freee 明細は全角・空白混じり(「ＡＮＴＨＲＯＰＩＣ＊  ＣＬＡＵＤＥ」)で来るので、
# 本番に入っている実データの表記をそのままテストに使う。
class MerchantCategoryGuesserTest < Minitest::Test
  def test_ai_and_saas_are_tsushinhi
    [
      "ＡＮＴＨＲＯＰＩＣ＊  ＣＬＡＵＤＥ  ＳＵ 220.00 USD",
      "ＡＮＴＨＲＯＰＩＣ 11.73 USD 165.719",
      "ＯＰＥＮＡＩ 11.00 USD 167.783 06/28",
      "ＺＯＯＭ．ＣＯＭ  ８８８―７９９―９６６",
      "ＣＡＮＶＡ＊  Ｉ０４９３０―２３５３２２",
      "ＶＲＥＷ",
      "ＧＯＯＧＬＥ　ＧＯＯＧＬＥ　ＯＮＥ",
      "ＦＬＹ．ＩＯ 5.09 USD 166.939",
      "７月分  ＫＤＤＩ利用料金"
    ].each do |description|
      assert_equal "通信費", MerchantCategoryGuesser.call(description), description
    end
  end

  def test_event_ticket_is_kenshuhi
    assert_equal "研修費", MerchantCategoryGuesser.call("Ｐｅａｔｉｘ  チケット")
    assert_equal "研修費", MerchantCategoryGuesser.call("connpass 参加費")
  end

  def test_goods_and_travel
    assert_equal "消耗品費", MerchantCategoryGuesser.call("ＡＭＡＺＯＮ．ＣＯ．ＪＰ")
    assert_equal "旅費交通費", MerchantCategoryGuesser.call("ブッキング・ドットコム・ジャパンカブシキ")
  end

  # AWS は Amazon より先に通信費として判定されること(物販ルールに食われない)
  def test_aws_is_not_treated_as_goods
    assert_equal "通信費", MerchantCategoryGuesser.call("AMAZON WEB SERVICES")
  end

  # 私的支出の疑いがあるもの・借入返済は判定しない(要確認のまま残す)
  def test_ambiguous_or_non_expense_is_not_guessed
    [ "証書貸付", "総合振込　　　　　　　ベン）アデイ−レホウ", "スマートゴルフ",
      "ワンストツプビヨウサロン  ミダシー", "" ].each do |description|
      assert_nil MerchantCategoryGuesser.call(description), description
    end
  end

  def test_returns_only_known_categories
    MerchantCategoryGuesser::RULES.each do |_, category|
      assert_includes BusinessExpense::ACCOUNT_CATEGORIES, category
    end
  end
end
