require "test_helper"

# WorkReport: 運送業(category=transport)向けの日報カラムのバリデーションと検印(approve!/unapprove!)。
class WorkReportTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "work_report_owner_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "運送 太郎", closing_day: 25)
    @admin = User.create!(email: "work_report_admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
  end

  def teardown
    [ @user, @admin ].compact.each(&:destroy)
  end

  def build_report(attrs = {})
    @user.work_reports.build({ work_date: Date.current, category: "transport" }.merge(attrs))
  end

  def test_distance_km_delivery_count_and_meter_values_must_be_zero_or_more
    report = build_report(distance_km: -1, delivery_count: -1, meter_start: -1, meter_end: -1)

    refute report.valid?
    refute_empty report.errors[:distance_km]
    refute_empty report.errors[:delivery_count]
    refute_empty report.errors[:meter_start]
    refute_empty report.errors[:meter_end]
  end

  def test_zero_is_a_valid_value_for_distance_and_meter_columns
    report = build_report(distance_km: 0, delivery_count: 0, meter_start: 0, meter_end: 0)

    assert report.valid?
  end

  def test_meter_end_must_not_be_less_than_meter_start
    report = build_report(meter_start: 100, meter_end: 99)

    refute report.valid?
    refute_empty report.errors[:meter_end]
  end

  def test_meter_end_equal_to_meter_start_is_valid
    report = build_report(meter_start: 100, meter_end: 100)

    assert report.valid?
  end

  def test_meter_validation_is_skipped_when_either_side_is_blank
    assert build_report(meter_start: 100, meter_end: nil).valid?
    assert build_report(meter_start: nil, meter_end: 100).valid?
  end

  def test_approved_is_false_until_approve_is_called
    report = build_report
    report.save!

    refute report.approved?
    assert_nil report.approved_at
    assert_nil report.approved_by
  end

  def test_approve_sets_approved_at_and_approved_by
    report = build_report
    report.save!

    report.approve!(actor: @admin)

    assert report.approved?
    refute_nil report.approved_at
    assert_equal @admin.id, report.approved_by_id
  end

  def test_unapprove_clears_approved_at_and_approved_by
    report = build_report
    report.save!
    report.approve!(actor: @user)

    report.unapprove!

    refute report.approved?
    assert_nil report.approved_at
    assert_nil report.approved_by
  end
end
