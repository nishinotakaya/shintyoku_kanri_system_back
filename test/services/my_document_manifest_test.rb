require "test_helper"

# MyDocumentManifest: ローカルフォルダ取り込み用の「本人の帳票だけ」一覧。
# 最重要: 他アカウントの帳票が絶対に混ざらないこと（admin であっても）。
class MyDocumentManifestTest < Minitest::Test
  def setup
    @owner = create_user("owner", display_name: "西野 鷹也")
    @other = create_user("other", display_name: "川村 卓也")
  end

  def teardown
    [ @owner, @other ].compact.each do |user|
      InvoiceSubmission.where(user_id: user.id).delete_all
      IssuedInvoicePdf.where(user_id: user.id).delete_all
      ReceivedPurchaseOrder.where(user_id: user.id).delete_all
      InvoiceSetting.where(user_id: user.id).delete_all
      user.destroy
    end
  end

  def create_user(prefix, display_name:)
    User.create!(email: "#{prefix}_#{SecureRandom.hex(4)}@example.com",
                 password: "password123", display_name: display_name, closing_day: 25)
  end

  def approved_invoice(user, month: 7, category: "wings", kind: "invoice")
    InvoiceSubmission.create!(user: user, year: 2026, month: month, category: category,
                              kind: kind, status: "approved", total_override: 100_000)
  end

  def issued_pdf(user, month: 6, category: "wings")
    IssuedInvoicePdf.create!(user: user, kind: "invoice", file_format: "pdf",
                             year: 2026, month: month, category: category,
                             filename: "#{user.display_name}_請求書.pdf",
                             file_data: "%PDF-1.4 dummy", generated_at: Time.current)
  end

  def purchase_order(user)
    ReceivedPurchaseOrder.create!(user: user, order_no: "ORD-#{SecureRandom.hex(3)}",
                                  category: "wings", period_start: Date.new(2026, 5, 26),
                                  period_end: Date.new(2026, 6, 25),
                                  filename: "注文書_#{user.display_name}.pdf",
                                  file_data: "%PDF-1.4 dummy")
  end

  # 1. 他ユーザーの帳票は 1 件も混ざらない。
  def test_excludes_other_users_documents
    approved_invoice(@owner)
    approved_invoice(@other)
    issued_pdf(@other)
    purchase_order(@other)

    documents = MyDocumentManifest.new(@owner).call

    assert documents.any?, "本人の帳票は取得できるべき"
    other_names = documents.select { |doc| doc[:filename].to_s.include?("川村") }
    assert_empty other_names, "他ユーザーの帳票が混ざってはいけない"
    assert_empty documents.select { |doc| doc[:key].to_s.start_with?("issued-", "purchase-order-") },
      "他ユーザーの確定PDF・注文書が混ざってはいけない"
  end

  # 2. admin でも他ユーザーぶんは返さない。
  def test_admin_still_gets_only_own_documents
    @owner.define_singleton_method(:admin?) { true }
    approved_invoice(@other)
    issued_pdf(@other)

    documents = MyDocumentManifest.new(@owner).call

    assert_empty documents, "admin でも他人の帳票は列挙しない"
  end

  # 3. fetch パラメータに as_user_id / invoice_submission_id を混ぜない
  #    （混ぜると admin が他人名義の帳票を取得できてしまう）。
  def test_fetch_params_never_target_another_user
    approved_invoice(@owner)

    MyDocumentManifest.new(@owner).call.each do |doc|
      params = doc.dig(:fetch, :params) || {}
      refute params.key?(:as_user_id), "as_user_id を含めてはいけない"
      refute params.key?(:invoice_submission_id), "invoice_submission_id を含めてはいけない"
    end
  end

  # 4. 月フォルダ名と種別が取り込み先の組み立てに使える形で入っている。
  def test_month_folder_and_labels
    approved_invoice(@owner, month: 7)

    invoice = MyDocumentManifest.new(@owner).call.find { |doc| doc[:doc_type] == "invoice" }

    assert_equal "2026年07月", invoice[:month_folder]
    assert_equal "請求書", invoice[:label]
    assert_equal "Wings", invoice[:category_label]
    assert_includes invoice[:filename], "西野"
    assert_equal "/exports/invoice.pdf", invoice.dig(:fetch, :path)
    assert_equal "2026-07", invoice.dig(:fetch, :params, :month)
  end

  # 5. 確定PDFがある月は、同じ内容の再生成版を重複して出さない。
  def test_issued_pdf_supersedes_generated_invoice
    approved_invoice(@owner, month: 6)
    issued_pdf(@owner, month: 6)

    documents = MyDocumentManifest.new(@owner).call
    june_invoices = documents.select { |doc| doc[:doc_type] == "invoice" && doc[:month] == 6 }

    assert_equal 1, june_invoices.size
    assert_includes june_invoices.first[:filename], "【確定】"
  end

  # 6. doc_types で対象を絞れる。
  def test_doc_types_filter
    approved_invoice(@owner)
    purchase_order(@owner)

    documents = MyDocumentManifest.new(@owner, doc_types: [ "purchase_order" ]).call

    assert documents.any?
    assert_equal [ "purchase_order" ], documents.map { |doc| doc[:doc_type] }.uniq
  end

  # 7. doc_types に work_report だけを指定しても業務報告書は 0 件にならない。
  #    業務報告書は kind="invoice" の承認済み申請から作るが、doc_types から "invoice" を
  #    外していても取得対象を絞り込む前の承認済み申請リストを参照できているべき。
  def test_doc_types_work_report_only_still_returns_work_reports
    approved_invoice(@owner, month: 7)

    documents = MyDocumentManifest.new(@owner, doc_types: [ "work_report" ]).call

    assert documents.any?, "work_report のみ指定でも業務報告書は返るべき"
    assert_equal [ "work_report" ], documents.map { |doc| doc[:doc_type] }.uniq
    work_report = documents.first
    assert_equal "/exports/work_report.xlsx", work_report.dig(:fetch, :path)
    assert_equal "2026-07", work_report.dig(:fetch, :params, :month)
  end
end
