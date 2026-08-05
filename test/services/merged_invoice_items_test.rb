require "test_helper"

# MergedInvoiceItems: 統合請求書の明細組み立て。
# 統合しても個別請求書と同じ単価・同じ行が出る（時給が下がらない）ことを検証する。
# 回帰: 「確定額(税抜) ÷ 稼働時間」で単価を逆算していたため、シェアラウンジ利用料(-30,000)などの
#       控除行が単価に溶けて 西野 3,750円/h が 3,310円/h に見えていた。
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
    InvoiceSetting.where(user_id: @user.id).delete_all
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

  # 1. 単価は個別請求書と同じ実時給。確定額を時間で割り戻した値にしない。
  #    確定額(575,300 税込 = 523,000 税抜)を 158h で割ると 3,310 になるが、それは出さない。
  def test_keeps_real_hourly_rate_when_merged
    add_hours(158)
    sub = make_sub(total_override: 575_300)

    items = MergedInvoiceItems.for_submission(sub)
    hour_item = items.find { |item| item[:unit] == "時間" }

    assert hour_item, "時間行が出るべき"
    assert_equal 158, hour_item[:qty]
    assert_equal 3750, hour_item[:unit_price], "実時給(3,750円)のまま。確定額÷時間で逆算しない"
    assert_equal 592_500, hour_item[:amount], "158h × 3,750円"
    assert_includes hour_item[:label], "西野 鷹也"
  end

  # 2. シェアラウンジ利用料などの控除行が、単価に溶けずに独立した行として残る。
  def test_keeps_deduction_line_as_separate_row
    add_hours(158)
    sub = make_sub(total_override: 575_300)

    items = MergedInvoiceItems.for_submission(sub)
    deduction = items.find { |item| item[:amount].negative? }

    assert deduction, "控除行(シェアラウンジ利用料)が残るべき"
    assert_equal(-30_000, deduction[:amount])
    assert_includes deduction[:label], "西野 鷹也"
  end

  # 3. 時給が引けないカテゴリ(resystems 等)は従来どおり「1式」にフォールバックする。
  def test_falls_back_to_lump_when_no_hourly_rate
    sub = make_sub(total_override: 100_000, category: "resystems")

    item = MergedInvoiceItems.for_submission(sub).first

    assert_equal "式", item[:unit]
    assert_equal 1, item[:qty]
    assert_equal 100_000, item[:amount], "resystems は税率0%なので税抜=税込"
  end

  # 4. items_override があれば実時給より優先してその明細を使う。
  def test_items_override_takes_precedence
    add_hours(158)
    sub = make_sub(total_override: 575_300,
      items_override: [ { "label" => "シェアラウンジ利用料", "qty" => 1, "unit" => "回", "unit_price" => -30_000, "amount" => -30_000 } ])

    items = MergedInvoiceItems.for_submission(sub)

    assert_equal 1, items.size
    assert_equal "回", items.first[:unit]
    assert_equal(-30_000, items.first[:amount])
  end

  # 5. 統合の請求金額は各申請の確定額の単純合計。明細合計(控除込み)には引きずられない。
  def test_confirmed_total_is_sum_of_submission_totals
    add_hours(158)
    sub = make_sub(total_override: 575_300)

    assert_equal 575_300, MergedInvoiceItems.confirmed_total([ sub ])
  end

  # 6. 不変条件: 明細合計(amount の合計) は必ず確定額(税抜) と一致する。
  #    158h × 3,750円 = 592,500 と控除 -30,000 の明細合計(562,500)は
  #    確定額(税抜) 523,000(=575,300÷1.1) と一致しないので、差額 -39,500 の「調整額」行が入る。
  def test_adds_adjustment_row_to_match_confirmed_subtotal
    add_hours(158)
    sub = make_sub(total_override: 575_300)

    items = MergedInvoiceItems.for_submission(sub)
    adjustment = items.find { |item| item[:label] == "調整額" }

    assert adjustment, "明細合計と確定額(税抜)がズレる場合は調整額行が入るべき"
    assert_equal(-39_500, adjustment[:amount])
    assert_equal 523_000, items.sum { |item| item[:amount].to_i }, "明細合計は確定額(税抜)と一致すること"
  end

  # 7. 明細行があっても合計が0円（0円行のみ）なら、確定額を説明できていないので1式にフォールバックする。
  #    techleaders は時給0・default_items が「プロアカ歩合報酬 1式 0円」のため、稼働0だと0円行1本だけになる。
  def test_falls_back_to_lump_when_items_sum_to_zero
    sub = make_sub(total_override: 50_000, category: "techleaders")

    items = MergedInvoiceItems.for_submission(sub)

    assert_equal 1, items.size
    assert_equal "式", items.first[:unit]
    assert_equal 1, items.first[:qty]
    assert_equal 50_000, items.first[:amount], "techleaders は税率0%なので税抜=税込"
  end

  # 8. total_override が無い申請（確定額という概念自体が無い）は調整額行を入れない。
  #    調整行は subtotal_of(=total_override÷税率) が 0 になるので、入れてしまうと
  #    「調整額 -明細合計」の行が明細合計を 0 円に打ち消してしまう。
  def test_no_adjustment_row_when_total_override_is_absent
    add_hours(158)
    sub = make_sub(total_override: nil)

    items = MergedInvoiceItems.for_submission(sub)

    refute items.any? { |item| item[:label] == "調整額" }, "total_override が無いときは調整額行を入れない"
    assert_equal 562_500, items.sum { |item| item[:amount].to_i }, "明細合計(158h×3,750-30,000)がそのまま残る"
  end

  # 9. total_override が無い申請の confirmed_total_for は、明細合計から請求額(税込)を算出する。
  #    修正前は調整額行で明細合計が 0 円に打ち消され、請求額まで 0 円になっていた。
  def test_confirmed_total_for_computes_from_items_when_total_override_is_absent
    add_hours(158)
    sub = make_sub(total_override: nil)

    # 562,500(明細合計・税抜) + 10%(wings の税率) = 618,750
    assert_equal 618_750, MergedInvoiceItems.confirmed_total_for(sub)
  end
end
