require "test_helper"

# Freee::BulkExpenseReporter: 選択した経費のうち freee 未連携分を一括計上する。
# AccountItemLookup / PartnerLookup / ReportSale はテスト用の差し替え(DI)でスタブし、
# 実際の freee へは接続しない。
class FreeeBulkExpenseReporterTest < Minitest::Test
  # ReportSale.call の戻り値互換オブジェクト。
  FakeReportResult = Struct.new(:ok?, :deal_id, :error, keyword_init: true)

  def setup
    @user = User.create!(
      email: "bulk_reporter_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "一括連携テスト"
    )
    @connection = FreeeConnection.new(user: @user, company_id: "999", session_cookie: "dummy_cookie")
  end

  def teardown
    @user.business_expenses.destroy_all
    @user.destroy
  end

  def test_succeeded_expense_is_marked_freee_synced_with_deal_id
    expense = create_expense(account_category: "旅費交通費", store_name: "JR東日本", freee_synced: false)
    reporter = build_reporter(
      account_item_lookup: stub_account_item_lookup("旅費交通費" => 501),
      partner_lookup: stub_partner_lookup("JR東日本" => 9001),
      report_sale_class: stub_report_sale_class(ok: true, deal_id: 7777)
    )

    result = reporter.call([ expense.id ])

    assert_equal [ { id: expense.id, deal_id: 7777 } ], result.succeeded
    assert_empty result.skipped
    assert_empty result.failed
    expense.reload
    assert expense.freee_synced?
    assert_equal 7777, expense.freee_deal_id
  end

  def test_already_synced_expense_is_skipped
    expense = create_expense(account_category: "旅費交通費", store_name: "JR東日本", freee_synced: true)
    reporter = build_reporter(
      account_item_lookup: stub_account_item_lookup("旅費交通費" => 501),
      partner_lookup: stub_partner_lookup("JR東日本" => 9001),
      report_sale_class: stub_report_sale_class(ok: true, deal_id: 7777)
    )

    result = reporter.call([ expense.id ])

    assert_equal [ { id: expense.id, reason: "連携済み" } ], result.skipped
    assert_empty result.succeeded
    assert_empty result.failed
  end

  def test_unresolvable_account_category_is_failed
    expense = create_expense(account_category: "旅費交通費", store_name: "JR東日本", freee_synced: false)
    reporter = build_reporter(
      account_item_lookup: stub_account_item_lookup({}), # 何も解決できない
      partner_lookup: stub_partner_lookup("JR東日本" => 9001),
      report_sale_class: stub_report_sale_class(ok: true, deal_id: 7777)
    )

    result = reporter.call([ expense.id ])

    assert_equal 1, result.failed.size
    assert_equal expense.id, result.failed.first[:id]
    assert_match(/勘定科目/, result.failed.first[:reason])
    refute expense.reload.freee_synced?
  end

  def test_blank_store_name_is_failed
    expense = create_expense(account_category: "旅費交通費", store_name: nil, freee_synced: false)
    reporter = build_reporter(
      account_item_lookup: stub_account_item_lookup("旅費交通費" => 501),
      partner_lookup: stub_partner_lookup({}),
      report_sale_class: stub_report_sale_class(ok: true, deal_id: 7777)
    )

    result = reporter.call([ expense.id ])

    assert_equal 1, result.failed.size
    assert_equal "店名が未入力です", result.failed.first[:reason]
  end

  def test_report_sale_failure_is_failed_with_reason
    expense = create_expense(account_category: "旅費交通費", store_name: "JR東日本", freee_synced: false)
    reporter = build_reporter(
      account_item_lookup: stub_account_item_lookup("旅費交通費" => 501),
      partner_lookup: stub_partner_lookup("JR東日本" => 9001),
      report_sale_class: stub_report_sale_class(ok: false, error: "deal 登録失敗 (status=400)")
    )

    result = reporter.call([ expense.id ])

    assert_equal 1, result.failed.size
    assert_equal "deal 登録失敗 (status=400)", result.failed.first[:reason]
    refute expense.reload.freee_synced?
  end

  def test_multiple_ids_are_processed_and_partitioned
    succeeded_expense = create_expense(account_category: "旅費交通費", store_name: "JR東日本", freee_synced: false)
    already_synced = create_expense(account_category: "旅費交通費", store_name: "JR東日本", freee_synced: true)
    unresolvable = create_expense(account_category: "消耗品費", store_name: "ヨドバシ", freee_synced: false)

    reporter = build_reporter(
      account_item_lookup: stub_account_item_lookup("旅費交通費" => 501),
      partner_lookup: stub_partner_lookup("JR東日本" => 9001, "ヨドバシ" => 9002),
      report_sale_class: stub_report_sale_class(ok: true, deal_id: 8888)
    )

    result = reporter.call([ succeeded_expense.id, already_synced.id, unresolvable.id ])

    assert_equal [ succeeded_expense.id ], result.succeeded.map { |row| row[:id] }
    assert_equal [ already_synced.id ], result.skipped.map { |row| row[:id] }
    assert_equal [ unresolvable.id ], result.failed.map { |row| row[:id] }
  end

  private

  def build_reporter(account_item_lookup:, partner_lookup:, report_sale_class:)
    Freee::BulkExpenseReporter.new(
      user: @user,
      connection: @connection,
      account_item_lookup: account_item_lookup,
      partner_lookup: partner_lookup,
      report_sale_class: report_sale_class
    )
  end

  def create_expense(account_category:, store_name:, freee_synced:)
    @user.business_expenses.create!(
      expense_date: Date.new(2026, 6, 15),
      store_name: store_name,
      amount: 3000,
      tax_rate: 10,
      account_category: account_category,
      status: "confirmed",
      freee_synced: freee_synced
    )
  end

  # name => account_item_id の Hash で find(name:) を返す簡易スタブ
  def stub_account_item_lookup(name_to_id)
    Class.new do
      define_method(:initialize) { |map| @map = map }
      define_method(:find) { |name:| @map[name] }
    end.new(name_to_id)
  end

  # name => partner_id の Hash で find_or_create(name:) を返す簡易スタブ
  def stub_partner_lookup(name_to_id)
    Class.new do
      define_method(:initialize) { |map| @map = map }
      define_method(:find_or_create) { |name:| @map[name] }
    end.new(name_to_id)
  end

  # ReportSale.new(...).call の戻り値を固定するスタブクラス(class自体を差し替える)
  def stub_report_sale_class(ok:, deal_id: nil, error: nil)
    result = FakeReportResult.new(ok?: ok, deal_id: deal_id, error: error)
    Class.new do
      define_method(:initialize) { |**_kwargs| }
      define_method(:call) { result }
    end
  end
end
