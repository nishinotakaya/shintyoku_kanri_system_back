require "test_helper"

# 外注パートナー合算(subcontract_incomes)の対象者選定テスト。
# 対象と合算開始月は users.subcontract_from(null=対象外)で管理する。
class TaxSummaryBuilderSubcontractTest < Minitest::Test
  def setup
    @admin = User.create!(
      email: "admin_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "西野 鷹也"
    )
  end

  def teardown
    @admin&.destroy
  end

  # subcontract_from が nil のパートナーは合算対象外
  def test_partner_without_subcontract_from_is_excluded
    partner = create_partner(subcontract_from: nil)
    create_approved_invoice(partner, year: 2026, month: 6)

    builder = TaxSummaryBuilder.new(@admin, 2026)
    result = builder.send(:subcontract_incomes)

    assert_empty result.select { |submission| submission.user_id == partner.id }
  ensure
    destroy_partner(partner)
  end

  # 合算開始年と同じ年は、開始月以降の請求のみ対象
  def test_current_year_only_includes_months_from_subcontract_start
    partner = create_partner(subcontract_from: Date.new(2026, 6, 1))
    before_start = create_approved_invoice(partner, year: 2026, month: 5)
    from_start = create_approved_invoice(partner, year: 2026, month: 6)
    after_start = create_approved_invoice(partner, year: 2026, month: 7)

    builder = TaxSummaryBuilder.new(@admin, 2026)
    result_ids = builder.send(:subcontract_incomes).select { |submission| submission.user_id == partner.id }.map(&:id)

    assert_equal [ from_start.id, after_start.id ].sort, result_ids.sort
    refute_includes result_ids, before_start.id
  ensure
    destroy_partner(partner)
  end

  # 合算開始年より後の年は、全月が対象
  def test_year_after_subcontract_start_includes_all_months
    partner = create_partner(subcontract_from: Date.new(2026, 6, 1))
    january = create_approved_invoice(partner, year: 2027, month: 1)

    builder = TaxSummaryBuilder.new(@admin, 2027)
    result_ids = builder.send(:subcontract_incomes).select { |submission| submission.user_id == partner.id }.map(&:id)

    assert_equal [ january.id ], result_ids
  ensure
    destroy_partner(partner)
  end

  # 合算開始年より前の年は対象外
  def test_year_before_subcontract_start_is_excluded
    partner = create_partner(subcontract_from: Date.new(2026, 6, 1))
    create_approved_invoice(partner, year: 2025, month: 12)

    builder = TaxSummaryBuilder.new(@admin, 2025)
    result = builder.send(:subcontract_incomes)

    assert_empty result.select { |submission| submission.user_id == partner.id }
  ensure
    destroy_partner(partner)
  end

  # admin 以外のユーザーのサマリでは、対象パートナーがいても常に空
  def test_non_admin_user_never_includes_subcontract_incomes
    partner = create_partner(subcontract_from: Date.new(2026, 6, 1))
    create_approved_invoice(partner, year: 2026, month: 6)
    non_admin = User.create!(
      email: "non_admin_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "テスト太郎"
    )

    builder = TaxSummaryBuilder.new(non_admin, 2026)

    assert_empty builder.send(:subcontract_incomes)
  ensure
    destroy_partner(partner)
    non_admin&.destroy
  end

  private

  # 請求書(FK制約あり)を先に削除してからパートナーを削除する
  def destroy_partner(partner)
    return unless partner
    InvoiceSubmission.where(user_id: partner.id).destroy_all
    partner.destroy
  end

  def create_partner(subcontract_from:)
    User.create!(
      email: "partner_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "パートナー#{SecureRandom.hex(2)}",
      subcontract_from: subcontract_from
    )
  end

  def create_approved_invoice(user, year:, month:)
    InvoiceSubmission.create!(
      user: user,
      year: year,
      month: month,
      kind: "invoice",
      status: "approved",
      total_override: 100_000
    )
  end
end
