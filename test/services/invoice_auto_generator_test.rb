require "test_helper"

# InvoiceAutoGenerator: 請求書の月次自動運転。毎日 cron から回るので全処理が冪等であること、
# 手編集した申請を勝手に上書きしないことを検証する。
# 締め日は25日 → 8/26〜9/25 が「2026年9月分」。
class InvoiceAutoGeneratorTest < Minitest::Test
  def setup
    @admin = User.create!(email: "autogen_admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @partner = User.create!(email: "autogen_partner_#{SecureRandom.hex(4)}@example.com",
                            password: "password123", display_name: "川村 卓也", closing_day: 25)
    @others = User.where.not(id: [ @admin.id, @partner.id ]).to_a
  end

  def teardown
    [ @admin, @partner ].compact.each do |user|
      InvoiceSubmission.where(user_id: user.id).delete_all
      WorkReport.where(user_id: user.id).delete_all
      InvoiceSetting.where(user_id: user.id).delete_all
      IssuedInvoicePdf.where(user_id: user.id).delete_all
      user.destroy
    end
  end

  def add_hours(user, total, category: "wings", from: Date.new(2026, 8, 26))
    date = from
    added = 0.0
    while added < total
      chunk = [ 8.0, total - added ].min
      WorkReport.create!(user: user, work_date: date, hours: chunk, category: category)
      added += chunk
      date += 1
    end
  end

  def subs_for(user, year: 2026, month: 9)
    InvoiceSubmission.where(user_id: user.id, year: year, month: month, kind: "invoice")
  end

  # 1. 稼働がある人には当月(9月分)の draft が自動で作られ、勤怠時間から請求額が入る。
  def test_creates_draft_for_users_with_hours
    add_hours(@admin, 24)
    @admin.invoice_setting_for("wings").update!(item_label: "開発支援業務", default_items: [])

    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 1))

    record = subs_for(@admin).find_by(category: "wings")
    assert record, "9月分の wings 申請が作られる"
    assert_equal "draft", record.status
    assert record.auto_synced?
    assert_equal((24 * 3750 * 1.1).round, record.total_override, "24h × 3,750円 × 1.1")
  end

  # 2. 稼働が無くても、前月に請求していたカテゴリは行を出す(月初に画面へ並べるため)。
  def test_creates_draft_for_recurring_category_without_hours
    InvoiceSubmission.create!(user: @admin, year: 2026, month: 8, category: "living",
                              kind: "invoice", status: "approved", total_override: 94_875)

    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 1))

    assert subs_for(@admin).exists?(category: "living"), "前月に請求した living は稼働0でも作る"
  end

  # 3. 何度実行しても二重に作らない(cron が毎日回る前提)。
  def test_is_idempotent
    add_hours(@admin, 24)

    3.times { InvoiceAutoGenerator.run(today: Date.new(2026, 9, 1)) }

    assert_equal 1, subs_for(@admin).where(category: "wings").count
  end

  # 4. 稼働が増えたら翌日の実行で請求額が追随する。
  def test_refreshes_total_as_hours_accumulate
    @admin.invoice_setting_for("wings").update!(default_items: [])
    add_hours(@admin, 24)
    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 1))
    add_hours(@admin, 8, from: Date.new(2026, 9, 10))

    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 11))

    assert_equal((32 * 3750 * 1.1).round, subs_for(@admin).find_by(category: "wings").total_override)
  end

  # 5. 金額を手で編集した申請(auto_synced=false)は上書きしない。
  def test_does_not_touch_manually_edited_submission
    @admin.invoice_setting_for("wings").update!(default_items: [])
    add_hours(@admin, 24)
    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 1))
    record = subs_for(@admin).find_by(category: "wings")
    record.update!(total_override: 123_456, auto_synced: false)
    add_hours(@admin, 8, from: Date.new(2026, 9, 10))

    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 11))

    assert_equal 123_456, record.reload.total_override, "手編集した金額は自動同期で戻さない"
  end

  # 6. 締めを過ぎたら前月分を承認し、統合請求書PDFを発行する。
  #    明細は請求時給(merged_unit_price) × 稼働時間。
  def test_finalizes_previous_month_with_merged_pdf
    add_hours(@admin, 100, from: Date.new(2026, 7, 26))
    add_hours(@partner, 80, from: Date.new(2026, 7, 26))
    @admin.invoice_setting_for("wings").update!(merged_unit_price: 3750, item_label: "開発支援業務", default_items: [])
    @partner.invoice_setting_for("wings").update!(merged_unit_price: 3500, item_label: "開発支援業務", default_items: [])
    [ @admin, @partner ].each do |user|
      InvoiceSubmission.create!(user: user, year: 2026, month: 8, category: "wings",
                                kind: "invoice", status: "draft", total_override: 1, auto_synced: true)
    end

    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 1))

    assert_equal %w[approved approved],
                 InvoiceSubmission.where(year: 2026, month: 8, category: "wings",
                                          user_id: [ @admin.id, @partner.id ]).pluck(:status)
    pdf = IssuedInvoicePdf.find_by(year: 2026, month: 8, category: "wings", kind: "invoice")
    assert pdf, "統合請求書PDFが発行される"
    assert pdf.merged
    subtotal = 100 * 3750 + 80 * 3500
    assert_equal((subtotal * 1.1).round, pdf.total_amount)
    assert_equal [ 3750, 3500 ], pdf.items_override.map { |row| row["unit_price"] }
  end

  # 7. 統合PDFが既にある月は再発行しない(手動発行と共存する)。
  def test_does_not_republish_existing_merged_pdf
    add_hours(@admin, 100, from: Date.new(2026, 7, 26))
    @admin.invoice_setting_for("wings").update!(merged_unit_price: 3750)
    InvoiceSubmission.create!(user: @admin, year: 2026, month: 8, category: "wings",
                              kind: "invoice", status: "approved", total_override: 100)
    existing = IssuedInvoicePdf.create!(user: @admin, kind: "invoice", file_format: "pdf",
                                         year: 2026, month: 8, category: "wings",
                                         total_amount: 999, filename: "手動.pdf", file_data: "x",
                                         generated_at: Time.current)

    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 1))

    assert_equal 1, IssuedInvoicePdf.where(year: 2026, month: 8, category: "wings", kind: "invoice").count
    assert_equal 999, existing.reload.total_amount, "既存の統合PDFは触らない"
  end

  # 8. 締め前(25日以前)は前月分をまだ確定させない。
  def test_does_not_finalize_before_closing_day
    InvoiceSubmission.create!(user: @admin, year: 2026, month: 9, category: "wings",
                              kind: "invoice", status: "draft", total_override: 100)

    InvoiceAutoGenerator.run(today: Date.new(2026, 9, 10))

    assert_equal "draft", subs_for(@admin).find_by(category: "wings").status,
                 "当月分(9/10 時点で 8/26〜9/25 の途中)は承認しない"
  end
end
