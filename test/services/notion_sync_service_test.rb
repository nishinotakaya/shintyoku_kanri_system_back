require "test_helper"

# NotionSyncService#upsert: Notion の現在値を無印列に書き、変わった項目の変更前の値を *_before_sync に退避する。
# WBS 画面で人が直した「修正後」(*_prev)には触らない。
# (同期のたびに *_prev が前回同期値で上書きされ、見積書の開始日が 7/7 に戻っていた事故の再発防止)
# Notion API は呼ばず、recordMap と同じ形の properties を組み立てて private の upsert を直接呼ぶ。
class NotionSyncServiceTest < ActiveSupport::TestCase
  def setup
    @block_id = SecureRandom.uuid
    @service = NotionSyncService.new
  end

  def teardown
    NotionTask.where(notion_block_id: @block_id).delete_all
  end

  def test_first_sync_stores_notion_values_without_before_sync
    upsert(start: "2026-09-01", finish: "2026-09-29", progress: "0.5", status: "進行中")

    task = NotionTask.find_by!(notion_block_id: @block_id)
    assert_equal Date.new(2026, 9, 1), task.start_date
    assert_equal Date.new(2026, 9, 29), task.end_date
    assert_in_delta 0.5, task.progress_rate, 0.001
    assert_equal "進行中", task.status
    assert_nil task.start_date_before_sync
    assert_nil task.status_before_sync
  end

  def test_changed_values_are_kept_in_before_sync_columns
    upsert(start: "2026-07-07", finish: "2026-07-14", progress: "0", status: "未着手")

    upsert(start: "2026-09-01", finish: "2026-09-29", progress: "1", status: "完了")

    task = NotionTask.find_by!(notion_block_id: @block_id)
    assert_equal Date.new(2026, 9, 1), task.start_date
    assert_equal Date.new(2026, 7, 7), task.start_date_before_sync
    assert_equal Date.new(2026, 7, 14), task.end_date_before_sync
    assert_in_delta 0.0, task.progress_rate_before_sync, 0.001
    assert_equal "未着手", task.status_before_sync
  end

  def test_sync_never_touches_wbs_overrides
    upsert(start: "2026-07-07", finish: "2026-07-14", progress: "0", status: "未着手")
    task = NotionTask.find_by!(notion_block_id: @block_id)
    task.update!(start_date_prev: Date.new(2026, 9, 1), end_date_prev: Date.new(2026, 9, 29),
                 progress_rate_prev: 1.0, status_prev: "進行中")

    upsert(start: "2026-08-01", finish: "2026-08-15", progress: "0.3", status: "進行中")

    task.reload
    assert_equal Date.new(2026, 9, 1), task.start_date_prev
    assert_equal Date.new(2026, 9, 29), task.end_date_prev
    assert_in_delta 1.0, task.progress_rate_prev, 0.001
    assert_equal "進行中", task.status_prev
    assert_equal Date.new(2026, 8, 1), task.start_date
  end

  private

  def upsert(start:, finish:, progress:, status:)
    ids = NotionClient::PROPERTY_IDS
    properties = {
      ids[:title]         => [ [ "見積書" ] ],
      ids[:wbs_level]     => [ [ "2.2.7.3.5" ] ],
      ids[:start_date]    => date_property(start),
      ids[:end_date]      => date_property(finish),
      ids[:progress_rate] => [ [ progress ] ],
      ids[:status]        => [ [ status ] ]
    }
    @service.send(:upsert, @block_id, properties, {})
  end

  # Notion の recordMap で日付プロパティが取る形: [["‣", [["d", { "start_date" => "YYYY-MM-DD" }]]]]
  def date_property(iso_date)
    [ [ "‣", [ [ "d", { "type" => "date", "start_date" => iso_date } ] ] ] ]
  end
end
