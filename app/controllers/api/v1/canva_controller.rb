require "digest"

module Api
  module V1
    # Canva Connect API の OAuth2(Authorization Code + PKCE)接続。
    # connect: 認可URLを返す / callback: コード交換しトークン保存(無認証・state照合)。
    class CanvaController < BaseController
      # callback は Canva からのブラウザリダイレクト(JWTなし)なので認証をスキップ。
      skip_before_action :authenticate_user!, only: :callback

      # GET /api/v1/canva/status
      def status
        render json: {
          configured: CanvaClient.configured?,
          connected: current_user.canva_refresh_token.present?
        }
      end

      # GET /api/v1/canva/connect  -> { authorize_url }
      def connect
        return render_error("Canva 連携が未設定です(管理者にCANVA_CLIENT_ID設定を依頼)") unless CanvaClient.configured?

        verifier = SecureRandom.urlsafe_base64(64)
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        state = SecureRandom.urlsafe_base64(24)
        current_user.update!(canva_oauth_state: state, canva_oauth_verifier: verifier)

        render json: { authorize_url: CanvaClient.authorize_url(state: state, code_challenge: challenge) }
      end

      # GET /api/v1/canva/callback?code=&state=
      def callback
        frontend = ENV.fetch("FRONTEND_ORIGIN", "http://localhost:5173")
        user = User.find_by(canva_oauth_state: params[:state].to_s.presence)
        return redirect_to("#{frontend}/interview-mindmap?canva=error", allow_other_host: true) unless user && params[:code].present?

        data = CanvaClient.exchange_code(code: params[:code], code_verifier: user.canva_oauth_verifier)
        user.update!(
          canva_access_token: data["access_token"],
          canva_refresh_token: data["refresh_token"],
          canva_token_expires_at: Time.current + data["expires_in"].to_i.seconds,
          canva_oauth_state: nil,
          canva_oauth_verifier: nil
        )
        redirect_to "#{frontend}/interview-mindmap?canva=connected", allow_other_host: true
      rescue => e
        Rails.logger.warn("[Canva callback] #{e.class}: #{e.message}")
        redirect_to "#{frontend}/interview-mindmap?canva=error", allow_other_host: true
      end

      # DELETE /api/v1/canva/disconnect
      def disconnect
        current_user.update!(canva_access_token: nil, canva_refresh_token: nil, canva_token_expires_at: nil)
        render json: { connected: false }
      end

      private

      def render_error(message, status: :unprocessable_entity)
        render json: { error: message }, status: status
      end
    end
  end
end
