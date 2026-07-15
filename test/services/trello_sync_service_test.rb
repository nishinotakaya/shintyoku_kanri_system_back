require "test_helper"

# TrelloSyncService: TrelloClient (Trello REST API) から取得したボード/リスト/カードを TrelloTask へ upsert する。
# 実際に Trello API へ接続すると壊れるため、TrelloClient.new をこのテストの間だけ差し替えてスタブする。
#
# 注: このプロジェクトの minitest (v6) には Object#stub (minitest/mock) が同梱されていないため、
# 既存テスト(interview_kanpe_generator_test.rb 等)に倣い、シングルトンメソッドの差し替え・復元でスタブする。
class TrelloSyncServiceTest < Minitest::Test
  def teardown
    TrelloTask.delete_all
  end

  # 1. カード2件(うち1件は closed=true)を返したとき、closed 以外の1件だけ TrelloTask に upsert される
  #    title, list_name, assignee_name, url が正しく入る
  def test_call_upserts_only_non_closed_cards_with_expected_fields
    fake_client = build_fake_client(
      board: { "name" => "テックリーダーズボード" },
      lists: [
        { "id" => "list-doing", "name" => "進行中" },
        { "id" => "list-done", "name" => "完了" }
      ],
      cards: [
        build_card(
          id: "card-open", name: "タスクA", idList: "list-doing",
          members: [ { "fullName" => "山田太郎" } ], shortUrl: "https://trello.com/c/open123",
          closed: false
        ),
        build_card(
          id: "card-closed", name: "タスクB", idList: "list-done",
          members: [ { "fullName" => "鈴木花子" } ], shortUrl: "https://trello.com/c/closed456",
          closed: true
        )
      ]
    )

    with_stubbed_trello_client(fake_client) { TrelloSyncService.call }

    assert_equal 1, TrelloTask.count
    task = TrelloTask.find_by!(trello_card_id: "card-open")
    assert_equal "タスクA", task.title
    assert_equal "進行中", task.list_name
    assert_equal "山田太郎", task.assignee_name
    assert_equal "https://trello.com/c/open123", task.url
    assert_nil TrelloTask.find_by(trello_card_id: "card-closed")
  end

  # 2. due "2026-07-15T15:00:00.000Z" が JST 変換され due_date が 2026-07-16 になること(start も同様)
  def test_call_converts_due_and_start_to_jst_date
    fake_client = build_fake_client(
      board: { "name" => "テックリーダーズボード" },
      lists: [ { "id" => "list-doing", "name" => "進行中" } ],
      cards: [
        build_card(
          id: "card-with-dates", name: "タスクC", idList: "list-doing",
          start: "2026-07-14T20:00:00.000Z",
          due: "2026-07-15T15:00:00.000Z"
        )
      ]
    )

    with_stubbed_trello_client(fake_client) { TrelloSyncService.call }

    task = TrelloTask.find_by!(trello_card_id: "card-with-dates")
    assert_equal Date.new(2026, 7, 16), task.due_date
    assert_equal Date.new(2026, 7, 15), task.start_date
  end

  # 3. 2回目の同期で Trello 側から消えたカードの TrelloTask が削除される
  def test_call_deletes_tasks_that_disappeared_from_trello
    first_client = build_fake_client(
      board: { "name" => "テックリーダーズボード" },
      lists: [ { "id" => "list-doing", "name" => "進行中" } ],
      cards: [
        build_card(id: "card-stays", name: "残るタスク", idList: "list-doing"),
        build_card(id: "card-disappears", name: "消えるタスク", idList: "list-doing")
      ]
    )
    with_stubbed_trello_client(first_client) { TrelloSyncService.call }
    assert_equal 2, TrelloTask.count

    second_client = build_fake_client(
      board: { "name" => "テックリーダーズボード" },
      lists: [ { "id" => "list-doing", "name" => "進行中" } ],
      cards: [
        build_card(id: "card-stays", name: "残るタスク", idList: "list-doing")
      ]
    )
    with_stubbed_trello_client(second_client) { TrelloSyncService.call }

    assert_equal 1, TrelloTask.count
    assert TrelloTask.exists?(trello_card_id: "card-stays")
    refute TrelloTask.exists?(trello_card_id: "card-disappears")
  end

  # 4. list_name「main マージ」は done: true、「作業中」は done: false になる
  def test_call_sets_done_flag_from_list_name
    fake_client = build_fake_client(
      board: { "name" => "テックリーダーズボード" },
      lists: [
        { "id" => "list-merge", "name" => "main マージ" },
        { "id" => "list-doing", "name" => "作業中" }
      ],
      cards: [
        build_card(id: "card-merged", name: "マージ済タスク", idList: "list-merge"),
        build_card(id: "card-doing", name: "作業中タスク", idList: "list-doing")
      ]
    )

    with_stubbed_trello_client(fake_client) { TrelloSyncService.call }

    assert TrelloTask.find_by!(trello_card_id: "card-merged").done
    refute TrelloTask.find_by!(trello_card_id: "card-doing").done
  end

  # 5. due が nil のカードでもエラーにならない
  def test_call_does_not_raise_when_due_is_nil
    fake_client = build_fake_client(
      board: { "name" => "テックリーダーズボード" },
      lists: [ { "id" => "list-doing", "name" => "進行中" } ],
      cards: [
        build_card(id: "card-no-due", name: "期限なしタスク", idList: "list-doing", due: nil, start: nil)
      ]
    )

    synced_count = nil
    with_stubbed_trello_client(fake_client) { synced_count = TrelloSyncService.call }

    assert_equal 1, synced_count
    task = TrelloTask.find_by!(trello_card_id: "card-no-due")
    assert_nil task.due_date
    assert_nil task.start_date
  end

  private

  # Trello API のカードレスポンスを模した Hash を組み立てる
  def build_card(id:, name:, idList:, desc: nil, idBoard: "board-1", members: [], start: nil, due: nil, shortUrl: "https://trello.com/c/#{id}", pos: 1, closed: false)
    {
      "id" => id,
      "name" => name,
      "desc" => desc,
      "idList" => idList,
      "idBoard" => idBoard,
      "members" => members,
      "start" => start,
      "due" => due,
      "shortUrl" => shortUrl,
      "pos" => pos,
      "closed" => closed
    }
  end

  # TrelloClient の代わりに fetch_board/fetch_lists/fetch_cards を固定値で返すフェイククライアントを組み立てる
  def build_fake_client(board:, lists:, cards:)
    fake_client = Object.new
    fake_client.define_singleton_method(:fetch_board) { board }
    fake_client.define_singleton_method(:fetch_lists) { lists }
    fake_client.define_singleton_method(:fetch_cards) { cards }
    fake_client
  end

  # TrelloClient.new をブロックの間だけ fake_client を返すよう差し替え、終了後に必ず元へ戻す。
  def with_stubbed_trello_client(fake_client)
    original_new = TrelloClient.method(:new)
    TrelloClient.define_singleton_method(:new) { |*args, **kwargs| fake_client }
    yield
  ensure
    TrelloClient.define_singleton_method(:new, original_new)
  end
end
