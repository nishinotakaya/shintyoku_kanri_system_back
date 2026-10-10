module Api
  module V1
    module Auth
      class OmniauthCallbacksController < Devise::OmniauthCallbacksController
        # API モードでは CSRF トークンがないのでスキップ
        skip_before_action :verify_authenticity_token, raise: false

        def google_oauth2
          auth = request.env["omniauth.auth"]
          user = User.from_google_oauth(auth)

          # Google トークン保存
          creds = auth.credentials
          user.update!(
            google_access_token: creds.token,
            google_refresh_token: creds.refresh_token || user.google_refresh_token,
            google_token_expires_at: creds.expires_at ? Time.at(creds.expires_at) : nil
          )

          sign_in(user)

          token = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first
          redirect_to "#{frontend_origin}/auth/callback?token=#{token}", allow_other_host: true
        end

        def failure
          redirect_to "#{frontend_origin}/sign_in?error=google_auth_failed", allow_other_host: true
        end

        private

        # ログインを始めた画面(旧URL/新URL)へ戻す。OmniAuth がリクエスト時の origin パラメータを omniauth.origin に保持している。
        def frontend_origin
          FrontendOrigin.resolve(request.env["omniauth.origin"])
        end
      end
    end
  end
end
