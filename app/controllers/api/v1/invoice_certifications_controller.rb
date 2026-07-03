module Api
  module V1
    # 請求書・支払通知書の電子証明(レベルA)。発行と公開検証。
    class InvoiceCertificationsController < BaseController
      skip_before_action :authenticate_user!, only: :verify

      # GET /api/v1/invoice_certifications?target_type=&target_id=
      def index
        scope = InvoiceCertification.order(signed_at: :desc)
        scope = scope.where(target_type: params[:target_type], target_id: params[:target_id]) if params[:target_id].present?
        render json: scope.limit(100).map(&:as_payload)
      end

      # POST /api/v1/invoice_certifications
      # { target_type, target_id, kind, payload:{金額・宛先・日付・明細...} }
      def create
        kind = params[:kind].presence || "application"
        return render_error("kind が不正です") unless InvoiceCertification::KINDS.include?(kind)
        return render_error("target が必要です") if params[:target_type].blank? || params[:target_id].blank?
        cert = InvoiceCertifier.certify(
          target_type: params[:target_type], target_id: params[:target_id].to_i,
          kind: kind, user: current_user,
          payload: (params[:payload] || {}).to_unsafe_h
        )
        render json: cert.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # GET /api/v1/invoice_certifications/verify/:token  (公開・認証不要)
      def verify
        result = InvoiceCertifier.verify(params[:token])
        return render(json: { valid: false, error: "証明が見つかりません" }, status: :not_found) unless result
        render json: { valid: true }.merge(result)
      end

      private

      def render_error(msg) = render(json: { error: msg }, status: :unprocessable_entity)
    end
  end
end
