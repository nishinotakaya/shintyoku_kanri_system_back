module Api
  module V1
    class IssuedInvoicePdfsController < BaseController
      # admin: 全件 / 自分のみ
      def index
        scope = current_user.admin? ? IssuedInvoicePdf.all : IssuedInvoicePdf.where(user_id: current_user.id)
        scope = scope.where(year: params[:year]) if params[:year].present?
        scope = scope.where(month: params[:month]) if params[:month].present?
        scope = scope.where(category: params[:category]) if params[:category].present?
        records = scope.order(generated_at: :desc).includes(:user)
        render json: records.map { |r| serialize(r) }
      end

      def show
        rec = current_user.admin? ? IssuedInvoicePdf.find(params[:id]) : current_user.issued_invoice_pdfs.find(params[:id])
        render json: serialize(rec)
      end

      # GET /api/v1/issued_invoice_pdfs/:id/download
      def download
        rec = current_user.admin? ? IssuedInvoicePdf.find(params[:id]) : IssuedInvoicePdf.where(user_id: current_user.id).find(params[:id])
        ctype = rec.file_format == "xlsx" ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/pdf"
        send_data rec.file_data, type: ctype, filename: rec.filename, disposition: params[:disposition].presence || "attachment"
      end

      def update
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        rec = IssuedInvoicePdf.find(params[:id])
        attrs = {}
        attrs[:purchase_order_no] = params[:purchase_order_no].to_s.presence if params.key?(:purchase_order_no)
        attrs[:filename] = params[:filename].to_s if params.key?(:filename) && params[:filename].to_s.present?
        attrs[:note] = params[:note].to_s.presence if params.key?(:note)
        rec.update!(attrs) if attrs.any?
        render json: serialize(rec)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def destroy
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        IssuedInvoicePdf.find(params[:id]).destroy!
        head :no_content
      end

      private

      def serialize(r)
        {
          id: r.id,
          user_id: r.user_id,
          user_display_name: r.user&.display_name,
          kind: r.kind,
          file_format: r.file_format,
          year: r.year,
          month: r.month,
          category: r.category,
          purchase_order_no: r.purchase_order_no,
          source_submission_ids: r.source_submission_ids,
          merged: r.merged,
          total_amount: r.total_amount,
          filename: r.filename,
          note: r.note,
          generated_at: r.generated_at&.iso8601
        }
      end
    end
  end
end
