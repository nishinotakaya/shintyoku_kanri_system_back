module Api
  module V1
    class PurchaseOrderHistoriesController < BaseController
      # GET /api/v1/purchase_order_histories?category=wings
      def index
        scope = current_user.purchase_order_histories
        scope = scope.where(category: params[:category]) if params[:category].present?
        records = scope.order(issued_at: :desc, id: :desc).limit(100)
        render json: records.map { |r| serialize(r) }
      end

      # POST /api/v1/purchase_order_histories
      # body: { payload: {...PurchaseOrder用 Hash...} }
      def create
        payload = params[:payload].respond_to?(:to_unsafe_h) ? params[:payload].to_unsafe_h : params[:payload].to_h
        items = Array(payload["items"] || payload[:items])
        total = items.sum { |it| (it["amount"] || it[:amount]).to_i }
        rec = current_user.purchase_order_histories.create!(
          category: params[:category].to_s.presence || "wings",
          position: params[:position].to_i,
          order_no: payload["order_no"] || payload[:order_no],
          subject: payload["subject"] || payload[:subject],
          recipient_name: (payload.dig("recipient", "name") || payload.dig(:recipient, :name)).to_s,
          period_start: parse_date(payload["period_start"] || payload[:period_start]),
          period_end:   parse_date(payload["period_end"]   || payload[:period_end]),
          total_amount: total,
          payload: payload,
          issued_at: Time.current
        )
        render json: serialize(rec), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/purchase_order_histories/:id/regenerate.pdf
      # 履歴 payload から PDF を再生成して返す
      def regenerate
        rec = current_user.purchase_order_histories.find(params[:id])
        path = PurchaseOrderPdfRenderer.new(current_user, rec.payload.deep_symbolize_keys).call
        send_file path, type: "application/pdf",
                  filename: "発注書_#{rec.order_no}.pdf", disposition: "attachment"
      end

      def destroy
        current_user.purchase_order_histories.find(params[:id]).destroy!
        head :no_content
      end

      private

      def parse_date(v)
        Date.iso8601(v.to_s) if v.present?
      rescue ArgumentError
        nil
      end

      def serialize(r)
        {
          id: r.id, category: r.category, position: r.position,
          order_no: r.order_no, subject: r.subject, recipient_name: r.recipient_name,
          period_start: r.period_start&.iso8601, period_end: r.period_end&.iso8601,
          total_amount: r.total_amount, issued_at: r.issued_at&.iso8601
        }
      end
    end
  end
end
