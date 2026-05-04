module Api
  module V1
    class ReceivedPurchaseOrdersController < BaseController
      before_action :ensure_admin, only: [ :create, :update, :destroy, :upload, :extract ]
      before_action :set_record, only: [ :show, :update, :destroy, :download ]

      # GET /api/v1/received_purchase_orders
      # admin: 全件 / それ以外: 自分のもの
      # ?year=2026&month=4 で期間絞り込み
      def index
        scope = current_user.admin? ? ReceivedPurchaseOrder.all : current_user.received_purchase_orders
        scope = scope.includes(:user, :invoice_submissions)
        scope = scope.for_year_month(params[:year], params[:month]) if params[:year].present?
        records = scope.order(period_start: :desc, order_no: :asc)
        render json: records.map { |r| serialize(r) }
      end

      def show
        render json: serialize(@record)
      end

      def create
        record = ReceivedPurchaseOrder.new(po_params)
        record.user_id ||= params[:user_id] || current_user.id
        record.save!
        render json: serialize(record), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def update
        @record.update!(po_params)
        render json: serialize(@record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def destroy
        @record.destroy!
        head :no_content
      end

      # POST /api/v1/received_purchase_orders/extract
      # multipart で PDF を受け取り、AI で抽出した JSON を返す（保存はしない）。
      # フロント側で内容確認 → upload で保存、の 2 ステップで使う想定。
      def extract
        file = params[:file]
        return render(json: { error: "PDF を添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)
        result = PurchaseOrderPdfExtractor.call(file.tempfile.presence || file)
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/received_purchase_orders/upload
      # multipart で PDF + 抽出 or 編集済みフィールドを受け取り、レコード作成 + PDF 保存。
      def upload
        file = params[:file]
        return render(json: { error: "PDF を添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        binary = file.read
        attrs = po_params.to_h.merge(
          file_data: binary,
          filename: file.original_filename,
          content_type: file.content_type || "application/pdf"
        )
        attrs[:user_id] ||= params[:user_id] || current_user.id
        attrs[:order_no] = "UNKNOWN-#{SecureRandom.hex(4)}" if attrs[:order_no].blank?
        attrs[:ai_extracted_at] = Time.current if params[:ai_extracted].to_s == "true"
        attrs[:ai_raw_text] = params[:ai_raw_text].to_s if params[:ai_raw_text].present?

        record = ReceivedPurchaseOrder.new(attrs)
        record.save!
        render json: serialize(record), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/received_purchase_orders/:id/download
      # 保存済 PDF をブラウザに送る。
      def download
        return render(json: { error: "PDF が保存されていません" }, status: :not_found) if @record.file_data.blank?
        send_data @record.file_data,
          type: @record.content_type.presence || "application/pdf",
          filename: @record.filename.presence || "発注書_#{@record.order_no}.pdf",
          disposition: params[:disposition].presence || "inline"
      end

      private

      def set_record
        @record = if current_user.admin?
                    ReceivedPurchaseOrder.find(params[:id])
        else
                    current_user.received_purchase_orders.find(params[:id])
        end
      end

      def po_params
        params.permit(:order_no, :customer_name, :category, :subject,
                      :period_start, :period_end, :total_amount, :note, :file_url, :user_id)
      end

      def ensure_admin
        unless current_user.admin?
          render json: { error: "admin only" }, status: :forbidden
        end
      end

      def serialize(r)
        {
          id: r.id,
          user_id: r.user_id,
          user_display_name: r.user&.display_name,
          order_no: r.order_no,
          customer_name: r.customer_name,
          category: r.category,
          subject: r.subject,
          period_start: r.period_start,
          period_end: r.period_end,
          total_amount: r.total_amount,
          note: r.note,
          file_url: r.file_url,
          filename: r.filename,
          has_pdf: r.file_data.present?,
          ai_extracted_at: r.ai_extracted_at&.iso8601,
          invoice_submission_count: r.invoice_submissions.size
        }
      end
    end
  end
end
