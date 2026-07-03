module Api
  module V1
    class ScannedInvoicesController < BaseController
      include FreeeReportable
      before_action :set_record, only: [ :show, :update, :destroy, :report_to_freee ]

      # GET /api/v1/scanned_invoices
      def index
        records = current_user.scanned_invoices.order(issue_date: :desc, id: :desc)
        render json: records.map { |r| serialize(r) }
      end

      def show
        render json: serialize(@record)
      end

      # POST /api/v1/scanned_invoices
      # multipart で PDF を受け取り、OCR して保存する。
      def create
        file = params[:file]
        return render(json: { error: "PDF を添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        # PDF 全体を base64 で保存 (確認モーダルでプレビュー表示するため)
        pdf_io = file.tempfile.presence || file
        pdf_io.rewind if pdf_io.respond_to?(:rewind)
        pdf_bytes = pdf_io.read
        pdf_base64 = Base64.strict_encode64(pdf_bytes)
        pdf_io.rewind if pdf_io.respond_to?(:rewind)

        result = InvoicePdfExtractor.call(pdf_io)

        record = current_user.scanned_invoices.create!(
          original_filename: file.original_filename,
          partner_name:    result[:partner_name],
          subject:         result[:subject],
          subtotal_amount: result[:subtotal_amount],
          tax_amount:      result[:tax_amount],
          total_amount:    result[:total_amount],
          issue_date:      result[:issue_date],
          due_date:        result[:due_date],
          invoice_number:  result[:invoice_number],
          raw_text:        result[:raw_text],
          raw_ai_response: result.reject { |k, _| k == :raw_text },
          status:          "pending",
          pdf_data:        pdf_base64,
          content_type:    (file.respond_to?(:content_type) ? file.content_type : nil) || "application/pdf"
        )

        render json: serialize(record), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/scanned_invoices/:id/attach_pdf
      # 既存レコードに後から PDF を attach する (PDF 保存機能リリース前のデータ救済用)。
      def attach_pdf
        record = current_user.scanned_invoices.find(params[:id])
        file = params[:file]
        return render(json: { error: "PDF を添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        io = file.tempfile.presence || file
        io.rewind if io.respond_to?(:rewind)
        record.update!(
          pdf_data: Base64.strict_encode64(io.read),
          content_type: (file.respond_to?(:content_type) ? file.content_type : nil) || "application/pdf"
        )
        render json: { success: true, has_pdf: true }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/scanned_invoices/:id/pdf
      # 保存済 PDF を inline 表示用に返す。
      def pdf
        record = current_user.scanned_invoices.find(params[:id])
        return head(:not_found) if record.pdf_data.blank?
        send_data Base64.strict_decode64(record.pdf_data),
                  type: record.content_type.presence || "application/pdf",
                  disposition: "inline",
                  filename: record.original_filename.presence || "invoice-#{record.id}.pdf"
      end

      def update
        @record.update!(record_params)
        render json: serialize(@record)
      end

      def destroy
        @record.destroy!
        head :no_content
      end

      # POST /api/v1/scanned_invoices/:id/report_to_freee
      def report_to_freee
        report_record_to_freee!(
          record: @record,
          invoice_payload: {
            total_amount: @record.total_amount,
            due_date: @record.due_date,
            subject: @record.subject
          },
          success_message: "freee に売上を計上しました"
        ) do |record, _result|
          record.update!(status: "confirmed")
          serialize(record)
        end
      end

      private

      def set_record
        @record = current_user.scanned_invoices.find(params[:id])
      end

      def record_params
        params.require(:scanned_invoice).permit(:partner_name, :subject, :subtotal_amount, :tax_amount, :total_amount, :issue_date, :due_date, :invoice_number, :status)
      end

      def serialize(r)
        {
          id: r.id,
          original_filename: r.original_filename,
          partner_name: r.partner_name,
          subject: r.subject,
          subtotal_amount: r.subtotal_amount,
          tax_amount: r.tax_amount,
          total_amount: r.total_amount,
          issue_date: r.issue_date,
          due_date: r.due_date,
          invoice_number: r.invoice_number,
          status: r.status,
          freee_deal_id: r.freee_deal_id,
          freee_reported_at: r.freee_reported_at,
          created_at: r.created_at,
          has_pdf: r.pdf_data.present?,
          pdf_url: r.pdf_data.present? ? "/api/v1/scanned_invoices/#{r.id}/pdf" : nil
        }
      end
    end
  end
end
