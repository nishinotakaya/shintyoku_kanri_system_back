require "test_helper"

# ExpenseCategoryDecider: 勘定科目を「摘要ルール → AI → 予備(freee推奨)」の順で決める。
# AI は本物を叩かないようスタブし、ルールで決まった行が AI に渡らないことも確かめる。
class ExpenseCategoryDeciderTest < Minitest::Test
  # TransactionCategorizer を差し替える。ブロックには AI に渡された行が渡る。
  def with_ai(results_by_description)
    original = TransactionCategorizer.method(:call)
    sent = []
    TransactionCategorizer.singleton_class.send(:define_method, :call) do |rows|
      sent.concat(rows)
      rows.map { |row| row.merge(results_by_description.fetch(row[:description], { account_category: nil, confidence: 0 })) }
    end
    yield sent
  ensure
    TransactionCategorizer.singleton_class.send(:define_method, :call, original)
  end

  def test_rule_decides_and_row_is_not_sent_to_ai
    with_ai({}) do |sent|
      decision = ExpenseCategoryDecider.call([ { description: "ＡＮＴＨＲＯＰＩＣ 11.73 USD", amount: 1700 } ]).first
      assert_equal "通信費", decision.account_category
      assert_equal "rule", decision.source
      assert_equal 100, decision.confidence
      refute decision.needs_review?
      assert_empty sent, "ルールで決まった行を AI に投げている"
    end
  end

  # ルールに無い行だけが AI に渡り、戻り値の順番は入力と一致する
  def test_ai_decides_only_unknown_rows_and_keeps_order
    with_ai({ "ＳＵＭＩＴＯＭＯ　ＲＥＮＴＡＣＡＲ" => { account_category: "車両費", confidence: 92 } }) do |sent|
      decisions = ExpenseCategoryDecider.call([
        { description: "ＡＭＡＺＯＮ．ＣＯ．ＪＰ", amount: 3000 },
        { description: "ＳＵＭＩＴＯＭＯ　ＲＥＮＴＡＣＡＲ", amount: 8000 }
      ])
      assert_equal [ "消耗品費", "車両費" ], decisions.map(&:account_category)
      assert_equal [ "rule", "ai" ], decisions.map(&:source)
      assert_equal [ "ＳＵＭＩＴＯＭＯ　ＲＥＮＴＡＣＡＲ" ], sent.map { |row| row[:description] }
      refute decisions.last.needs_review?
    end
  end

  # 確信度が低い AI 判定は、科目は入れるが要確認に回す
  def test_low_confidence_ai_decision_needs_review
    with_ai({ "ナゾノミセ" => { account_category: "雑費", confidence: 40 } }) do |_sent|
      decision = ExpenseCategoryDecider.call([ { description: "ナゾノミセ", amount: 1200 } ]).first
      assert_equal "雑費", decision.account_category
      assert decision.needs_review?
    end
  end

  # AI が科目を決められなかったときだけ予備(freee の推奨科目)を使う
  def test_fallback_category_is_used_last
    with_ai({}) do |_sent|
      decision = ExpenseCategoryDecider.call([
        { description: "ナゾノミセ", amount: 1200, fallback_category: "接待交際費" }
      ]).first
      assert_equal "接待交際費", decision.account_category
      assert_equal "fallback", decision.source
      assert decision.needs_review?, "freee の推奨科目は当てにならないので要確認で残す"
    end
  end

  # 科目リストに無い名前(freee 独自名・AI の暴走)は採用しない
  def test_unknown_category_names_are_rejected
    with_ai({ "ナゾノミセ" => { account_category: "交際費", confidence: 99 } }) do |_sent|
      decision = ExpenseCategoryDecider.call([
        { description: "ナゾノミセ", amount: 1200, fallback_category: "雑収入" }
      ]).first
      assert_nil decision.account_category
      assert decision.needs_review?
    end
  end

  # AI が落ちても例外は投げず、要確認として残す(登録自体は通す)
  def test_ai_failure_does_not_raise
    original = TransactionCategorizer.method(:call)
    TransactionCategorizer.singleton_class.send(:define_method, :call) { |_rows| raise "OpenAI API error: 500" }
    decisions = ExpenseCategoryDecider.call([ { description: "ナゾノミセ", amount: 1200 } ])
    assert_nil decisions.first.account_category
    assert decisions.first.needs_review?
  ensure
    TransactionCategorizer.singleton_class.send(:define_method, :call, original)
  end
end
