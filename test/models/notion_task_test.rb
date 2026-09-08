require "test_helper"

# NotionTask#unsubmitted_override? / #mark_overrides_submitted!: WBS Excel 書き出しの赤塗り判定に使う。
# 「修正後(*_prev)がある」かつ「提出済スナップショット(wbs_submitted_overrides)と異なる」場合だけ true。
class NotionTaskTest < Minitest::Test
  def setup
    @task = NotionTask.create!(
      notion_block_id: SecureRandom.uuid, wbs_level: "1.1", title: "元タイトル",
      assignee_name: "担当A", workload: 1, progress_rate: 0,
      start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 10),
      synced_at: Time.current
    )
  end

  def teardown
    @task.destroy
  end

  def test_unsubmitted_override_is_false_when_prev_is_absent
    refute @task.unsubmitted_override?(:start_date)
  end

  def test_unsubmitted_override_is_true_when_prev_present_and_not_yet_submitted
    @task.update!(start_date_prev: Date.new(2026, 9, 20))

    assert @task.unsubmitted_override?(:start_date)
  end

  def test_unsubmitted_override_becomes_false_after_marking_submitted
    @task.update!(start_date_prev: Date.new(2026, 9, 20))
    @task.mark_overrides_submitted!

    refute @task.unsubmitted_override?(:start_date)
  end

  def test_unsubmitted_override_becomes_true_again_after_a_further_change
    @task.update!(start_date_prev: Date.new(2026, 9, 20))
    @task.mark_overrides_submitted!
    @task.update!(start_date_prev: Date.new(2026, 9, 25))

    assert @task.unsubmitted_override?(:start_date)
  end

  def test_override_present_treats_zero_as_present
    @task.update!(progress_rate_prev: 0)

    assert @task.override_present?(:progress_rate)
  end

  def test_mark_overrides_submitted_only_snapshots_present_overrides
    @task.update!(title_prev: "修正後タイトル")

    @task.mark_overrides_submitted!

    assert_equal({ "title" => "修正後タイトル" }, @task.wbs_submitted_overrides)
  end
end
