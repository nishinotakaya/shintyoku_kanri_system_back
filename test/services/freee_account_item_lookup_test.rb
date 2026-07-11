require "test_helper"

# Freee::AccountItemLookup: 勘定科目名 → account_item_id 解決。
# 実際の freee へは接続せず、private #get を差し替えたサブクラスで HTTP レスポンスを固定する。
class FreeeAccountItemLookupTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  # #get(uri) だけを固定レスポンスに差し替えたテスト用サブクラス。
  class StubbedLookup < Freee::AccountItemLookup
    def initialize(response_body:, status: "200", connection: FreeeConnection.new(session_cookie: "dummy_cookie"), company_id: "999")
      @stub_response = FakeResponse.new(status, response_body)
      super(connection: connection, company_id: company_id)
    end

    private

    def get(_uri)
      @stub_response
    end
  end

  def test_exact_match_resolves_account_item_id
    body = { "account_items" => [
      { "id" => 111, "name" => "旅費交通費" },
      { "id" => 222, "name" => "通信費" }
    ] }.to_json
    lookup = StubbedLookup.new(response_body: body)

    assert_equal 222, lookup.find(name: "通信費")
  end

  def test_prefix_match_resolves_when_no_exact_match
    body = { "account_items" => [
      { "id" => 333, "name" => "接待交際費(社内)" }
    ] }.to_json
    lookup = StubbedLookup.new(response_body: body)

    assert_equal 333, lookup.find(name: "接待交際費")
  end

  def test_returns_nil_when_no_match_found
    body = { "account_items" => [
      { "id" => 111, "name" => "旅費交通費" }
    ] }.to_json
    lookup = StubbedLookup.new(response_body: body)

    assert_nil lookup.find(name: "存在しない科目")
  end

  def test_returns_nil_when_name_is_blank
    lookup = StubbedLookup.new(response_body: { "account_items" => [] }.to_json)

    assert_nil lookup.find(name: "")
  end

  def test_list_is_memoized_and_fetched_only_once
    body = { "account_items" => [ { "id" => 111, "name" => "旅費交通費" } ] }.to_json
    call_count = 0
    lookup = StubbedLookup.new(response_body: body)
    lookup.define_singleton_method(:get) do |uri|
      call_count += 1
      FakeResponse.new("200", body)
    end

    lookup.find(name: "旅費交通費")
    lookup.find(name: "旅費交通費")

    assert_equal 1, call_count, "一覧取得は1回のGETにメモ化されるべき"
  end
end
