module Api
  module V1
    class PurchaseOrderHistoriesController < BaseController
      # GET /api/v1/purchase_order_histories?category=wings
      # admin (西野) は全件、それ以外 (川村など) は recipient_user_id=自分のみ
      def index
        scope = current_user.admin? ? PurchaseOrderHistory.all : PurchaseOrderHistory.where(recipient_user_id: current_user.id)
        scope = scope.where(category: params[:category]) if params[:category].present?
        records = scope.order(issued_at: :desc, id: :desc).limit(100)
        render json: records.map { |r| serialize(r) }
      end

      # POST /api/v1/purchase_order_histories
      # body: { payload: {...PurchaseOrder用 Hash...}, recipient_user_id: 5 }
      def create
        payload = params[:payload].respond_to?(:to_unsafe_h) ? params[:payload].to_unsafe_h : params[:payload].to_h
        items = Array(payload["items"] || payload[:items])
        total = items.sum { |it| (it["amount"] || it[:amount]).to_i }
        recipient_user_id = params[:recipient_user_id].presence&.to_i || default_recipient_user_id
        rec = current_user.purchase_order_histories.create!(
          category: params[:category].to_s.presence || "wings",
          position: params[:position].to_i,
          order_no: payload["order_no"] || payload[:order_no],
          subject: payload["subject"] || payload[:subject],
          recipient_name: (payload.dig("recipient", "name") || payload.dig(:recipient, :name)).to_s,
          recipient_user_id: recipient_user_id,
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
        rec = scoped.find(params[:id])
        path = PurchaseOrderPdfRenderer.new(rec.user, rec.payload.deep_symbolize_keys).call
        send_file path, type: "application/pdf",
                  filename: "発注書_#{rec.order_no}.pdf", disposition: "attachment"
      end

      def destroy
        scoped.find(params[:id]).destroy!
        head :no_content
      end

      private

      def scoped
        current_user.admin? ? PurchaseOrderHistory.all : PurchaseOrderHistory.where(recipient_user_id: current_user.id)
      end

      # 受注者未指定で発行された場合のデフォルト = 川村 (calmdownyourlife@gmail.com / id=5)
      def default_recipient_user_id
        User.find_by(email: "calmdownyourlife@gmail.com")&.id || 5
      end

      def parse_date(v)
        Date.iso8601(v.to_s) if v.present?
      rescue ArgumentError
        nil
      end

      def serialize(r)
        # DB の total_amount は items 合計 (税抜)。一覧表示は 税込 で揃えるため 10% 加算して返す
        total_with_tax = r.total_amount.present? ? (r.total_amount * 1.1).round : nil
        {
          id: r.id, category: r.category, position: r.position,
          order_no: r.order_no, subject: r.subject, recipient_name: r.recipient_name,
          recipient_user_id: r.recipient_user_id,
          recipient_user_display_name: r.recipient_user&.display_name,
          issuer_user_id: r.user_id,
          issuer_user_display_name: r.user&.display_name,
          period_start: r.period_start&.iso8601, period_end: r.period_end&.iso8601,
          total_amount: total_with_tax, issued_at: r.issued_at&.iso8601
        }
      end
    end
  end
end
