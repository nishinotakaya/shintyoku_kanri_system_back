require "test_helper"

# MergedInvoiceItems: 統合請求書の明細組み立て。
# 稼働時間があれば「時間×単価」で出す(金額が時間で割り切れなくても1式に落とさない)ことを検証する。
# 回帰: 西野 523,000円(税抜) ÷ 158時間 は余り20円 → 以前は「1式」になっていた。
class MergedInvoiceItemsTest < Minitest::Test
  def setup
    @user = User.create!(
      email: "merged_items_#{SecureRandom.hex(4)}@example.com",
      password: "password123", display_name: "西野 鷹也", closing_day: 25
    )
  end

  def teardown
    return unless @user
    InvoiceSubmission.where(user_id: @user.id).delete_all
    WorkReport.where(user_id: @user.id).delete_all
    @user.destroy
  end

  # 2026/7 締(6/26〜7/25)に指定時間ぶんの work_reports を積む
  def add_hours(total, category: "wings")
    date = Date.new(2026, 6, 26)
    added = 0.0
    while added < total
      chunk = [ 8.0, total - added ].min
      WorkReport.create!(user: @user, work_date: date, hours: chunk, category: category)
      added += chunk
      date += 1
    end
  end

  def make_sub(total_override:, category: "wings", items_override: nil)
    InvoiceSubmission.create!(
      user: @user, year: 2026, month: 7, category: category, kind: "invoice", status: "approved",
      total_override: total_override, items_override: items_override
    )
  end

  # 1. 割り切れない時間でも「時間×単価(四捨五入)」で出す。金額は確定額のまま。
  def test_non_divisible_hours_shows_time_not_lump
    add_hours(158)
    sub = make_sub(total_override: 575_300) # 税込・wings(10%) → 税抜 523,000

    items = MergedInvoiceItems.for_submission(sub)

    assert_equal 1, items.size
    item = items.first
    assert_equal "時間", item[:unit], "1式ではなく時間表記になるべき"
    assert_equal 158, item[:qty]
    assert_equal 523_000, item[:amount], "金額は税抜確定額そのまま"
    assert_equal 3310, item[:unit_price], "単価=四捨五入(523000/158)"
    assert_includes item[:label], "西野 鷹也"
  end

  # 2. 稼働0時間のときは従来どおり「1式」にフォールバックする。
  def test_zero_hours_falls_back_to_lump
    sub = make_sub(total_override: 100_000)

    item = MergedInvoiceItems.for_submission(sub).first

    assert_equal "式", item[:unit]
    assert_equal 1, item[:qty]
  end

  # 3. items_override があれば時間表記より優先してその明細を使う。
  def test_items_override_takes_precedence
    add_hours(158)
    sub = make_sub(total_override: 575_300,
      items_override: [ { "label" => "シェアラウンジ利用料", "qty" => 1, "unit" => "回", "unit_price" => -30_000, "amount" => -30_000 } ])

    items = MergedInvoiceItems.for_submission(sub)

    assert_equal 1, items.size
    assert_equal "回", items.first[:unit]
    assert_equal(-30_000, items.first[:amount])
  end
end
