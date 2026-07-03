class IssuedInvoicePdfVersion < ApplicationRecord
  belongs_to :issued_invoice_pdf

  serialize :source_submission_ids, coder: JSON
  serialize :items_override, coder: JSON

  # 上書き直前の issued_invoice_pdf の中身を丸ごと退避したスナップショットを作る。
  # file_data(PDF/Excel 実体) ごと保存するので、これ 1 行で完全復元できる。
  def self.archive!(record, reason:)
    create!(
      issued_invoice_pdf_id: record.id,
      user_id:               record.user_id,
      kind:                  record.kind,
      file_format:           record.file_format,
      year:                  record.year,
      month:                 record.month,
      category:              record.category,
      purchase_order_no:     record.purchase_order_no,
      source_submission_ids: record.source_submission_ids,
      merged:                record.merged,
      total_amount:          record.total_amount,
      filename:              record.filename,
      file_data:             record.file_data,
      note:                  record.note,
      items_override:        record.items_override,
      original_generated_at: record.generated_at,
      reason:                reason
    )
  end

  # このバージョンの内容を、退避元の issued_invoice_pdf へ書き戻す(元に戻す)。
  def restore_to_source!
    issued_invoice_pdf.update!(
      purchase_order_no: purchase_order_no,
      total_amount:      total_amount,
      filename:          filename,
      file_data:         file_data,
      note:              note,
      items_override:    items_override,
      generated_at:      original_generated_at || Time.current
    )
  end
end
