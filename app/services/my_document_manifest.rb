# ログイン中ユーザー「本人の」帳票だけを列挙して、ローカルフォルダ取り込み用の一覧を返す。
#
# 重要: ここで他ユーザーの帳票を混ぜてはいけない。
#   - すべてのクエリを user_id = 本人 で絞る（admin でも他人の分は返さない）
#   - 返す fetch.path には as_user_id / invoice_submission_id を一切含めない
#     （含めると admin が他人名義の帳票を取れてしまうため）
class MyDocumentManifest
  DOC_TYPE_LABELS = {
    "invoice" => "請求書",
    "expense" => "立替金",
    "purchase_order" => "注文書",
    "work_report" => "業務報告書"
  }.freeze

  def initialize(user, doc_types: DOC_TYPE_LABELS.keys)
    @user = user
    @doc_types = Array(doc_types).map(&:to_s) & DOC_TYPE_LABELS.keys
  end

  def call
    documents = []
    documents.concat(issued_pdf_documents)
    documents.concat(submission_documents)
    documents.concat(purchase_order_documents)
    documents.concat(work_report_documents)
    documents.sort_by { |doc| [ -doc[:year].to_i, -doc[:month].to_i, doc[:doc_type], doc[:filename] ] }
  end

  private

  attr_reader :user

  def include?(doc_type)
    @doc_types.include?(doc_type)
  end

  # 1) 本人が発行した確定PDF（統合請求書・立替金）。実体が DB にあるのでそのまま落とせる。
  def issued_pdf_documents
    IssuedInvoicePdf.where(user_id: user.id).select { |record| include?(record.kind) }.map do |record|
      document(
        key: "issued-#{record.id}",
        doc_type: record.kind,
        year: record.year, month: record.month, category: record.category,
        filename: "【確定】#{record.filename}",
        path: "/issued_invoice_pdfs/#{record.id}/download"
      )
    end
  end

  # 2) 本人の承認済み申請から生成する請求書 / 立替金。
  #    確定PDFが既にある (年・月・カテゴリ・種別) は重複するので出さない。
  def submission_documents
    covered = IssuedInvoicePdf.where(user_id: user.id)
                              .map { |record| [ record.kind, record.year, record.month, record.category ] }.to_set

    approved_submissions.reject { |submission|
      covered.include?([ submission.kind, submission.year, submission.month, submission.category ])
    }.map do |submission|
      extension = submission.kind == "expense" ? "expense.pdf" : "invoice.pdf"
      document(
        key: "submission-#{submission.id}",
        doc_type: submission.kind,
        year: submission.year, month: submission.month, category: submission.category,
        filename: file_name_for(submission.kind, submission.year, submission.month, submission.category, "pdf"),
        path: "/exports/#{extension}",
        params: { month: year_month_param(submission.year, submission.month), category: submission.category }
      )
    end
  end

  # 3) 本人宛に受領した注文書（PDF 実体があるものだけ）。
  def purchase_order_documents
    return [] unless include?("purchase_order")

    ReceivedPurchaseOrder.where(user_id: user.id).reject { |record| record.file_data.blank? }.map do |record|
      issued_on = record.period_start || record.created_at.to_date
      document(
        key: "purchase-order-#{record.id}",
        doc_type: "purchase_order",
        year: issued_on.year, month: issued_on.month, category: record.category,
        filename: record.filename.presence || "注文書_#{record.order_no}.pdf",
        path: "/received_purchase_orders/#{record.id}/download"
      )
    end
  end

  # 4) 請求書を出した月ぶんの業務報告書。請求書の裏付けなので同じ (年・月・カテゴリ) で揃える。
  def work_report_documents
    return [] unless include?("work_report")

    approved_submissions.select { |submission| submission.kind == "invoice" }
                        .map { |submission| [ submission.year, submission.month, submission.category ] }
                        .uniq
                        .map do |year, month, category|
      document(
        key: "work-report-#{year}-#{month}-#{category}",
        doc_type: "work_report",
        year: year, month: month, category: category,
        filename: file_name_for("work_report", year, month, category, "xlsx"),
        path: "/exports/work_report.xlsx",
        params: { month: year_month_param(year, month), category: category }
      )
    end
  end

  def approved_submissions
    @approved_submissions ||= InvoiceSubmission.where(user_id: user.id).approved
                                               .select { |submission| include?(submission.kind) }
  end

  def document(key:, doc_type:, year:, month:, category:, filename:, path:, params: {})
    {
      key: key,
      doc_type: doc_type,
      label: DOC_TYPE_LABELS[doc_type],
      year: year, month: month,
      category: category,
      category_label: InvoiceSetting.category_label(category),
      month_folder: month_folder_for(year, month),
      filename: filename,
      fetch: { path: path, params: params }
    }
  end

  def file_name_for(doc_type, year, month, category, extension)
    parts = [ InvoiceSetting.category_label(category), surname, DOC_TYPE_LABELS[doc_type],
              "#{year}年_#{month}月分" ]
    "#{parts.map { |part| part.to_s.strip }.reject(&:blank?).join('_')}.#{extension}"
  end

  def surname
    @surname ||= user.display_name.to_s.split(/[\s　]/).first
  end

  def month_folder_for(year, month)
    return "年月不明" if year.blank? || month.blank?
    format("%04d年%02d月", year.to_i, month.to_i)
  end

  def year_month_param(year, month)
    format("%04d-%02d", year.to_i, month.to_i)
  end
end
