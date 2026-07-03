require "test_helper"

# 作成は「下書き(draft)」のみ。申請(submit)で pending/approved へ進む運用の回帰ガード。
class InvoiceSubmissionTest < Minitest::Test
  def test_draft_is_a_valid_status
    assert_includes InvoiceSubmission::STATUSES, "draft"
  end

  def test_new_record_defaults_to_draft
    r = InvoiceSubmission.new(kind: "invoice", year: 2026, month: 6)
    r.valid? # before_validation :set_defaults を走らせる(保存はしない)
    assert_equal "draft", r.status, "新規作成のデフォルトが draft でない(作成=申請に戻っている)"
  end

  def test_draft_scope_filters_by_status
    assert_equal "draft", InvoiceSubmission.draft.where_values_hash["status"]
  end
end
