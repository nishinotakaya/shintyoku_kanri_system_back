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

  # title/assignee_name はテンプレ(E〜H列)に対応するセルが無いため、常に「異なる」扱いになる
  def test_template_differs_is_always_true_for_fields_not_covered_by_the_template
    assert @task.template_differs?(:title, { progress_rate: 0, workload: 1 })
  end

  # red_cell?: テンプレ未登録・該当行なし(template_row が nil)で未提出の修正後があれば赤
  def test_red_cell_is_true_when_no_template_row_and_unsubmitted
    @task.update!(start_date_prev: Date.new(2026, 9, 20))

    assert @task.red_cell?(:start_date, nil)
  end

  # red_cell?: テンプレの値と同じ修正後は赤にしない(出力しても見た目が変わらないため)
  def test_red_cell_is_false_when_matches_template_value
    @task.update!(start_date_prev: Date.new(2026, 9, 20))

    refute @task.red_cell?(:start_date, { start_date: Date.new(2026, 9, 20) })
  end

  # red_cell?: テンプレの値と異なる修正後は赤にする
  def test_red_cell_is_true_when_differs_from_template_value
    @task.update!(start_date_prev: Date.new(2026, 9, 20))

    assert @task.red_cell?(:start_date, { start_date: Date.new(2026, 9, 25) })
  end

  # red_cell?: 提出済にした修正後はテンプレと異なっていても赤にしない
  def test_red_cell_is_false_when_already_submitted
    @task.update!(start_date_prev: Date.new(2026, 9, 20))
    @task.mark_overrides_submitted!

    refute @task.red_cell?(:start_date, { start_date: Date.new(2026, 9, 25) })
  end

  # red_cell?: 完了扱い(実効進捗率100%以上)のタスクは報告対象外として赤にしない
  def test_red_cell_is_false_when_effective_progress_rate_is_complete
    @task.update!(start_date_prev: Date.new(2026, 9, 20), progress_rate: 1.0)

    refute @task.red_cell?(:start_date, { start_date: Date.new(2026, 9, 25) })
  end
end
