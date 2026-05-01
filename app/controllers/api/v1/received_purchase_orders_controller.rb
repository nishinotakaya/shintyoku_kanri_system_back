module Api
  module V1
    class ReceivedPurchaseOrdersController < BaseController
      before_action :ensure_admin, only: [ :create, :update, :destroy ]
      before_action :set_record, only: [ :show, :update, :destroy ]

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
          invoice_submission_count: r.invoice_submissions.size
        }
      end
    end
  end
end
