module Api
  module V1
    module Public
      # 招待メール記載の登録リンク(/invite/:token)向けの公開エンドポイント。ログイン不要。
      # トークンは User#signed_id(purpose: :invitation, 14日期限)。
      # 使用済みは users.invitation_accepted_at で判定し、再利用(パスワードの上書き)を防ぐ。
      class InvitationsController < BaseController
        skip_before_action :authenticate_user!

        before_action :set_no_index_headers
        before_action :set_invitee

        # GET /api/v1/public/invitations/:token
        def show
          render json: {
            email: @invitee.email,
            display_name: @invitee.display_name,
            accepted: @invitee.invitation_accepted_at.present?
          }
        end

        # POST /api/v1/public/invitations/:token/accept { password, display_name }
        # パスワードを設定して登録を完了し、そのままログインできる JWT を返す。
        def accept
          if @invitee.invitation_accepted_at.present?
            return render(json: { error: "この招待は既に使用されています。ログイン画面からログインしてください" }, status: :conflict)
          end

          @invitee.update!(
            password: params[:password].to_s,
            display_name: params[:display_name].to_s.strip.presence || @invitee.display_name,
            invitation_accepted_at: Time.current
          )
          send_confirmation_mail
          token, _payload = Warden::JWTAuth::UserEncoder.new.call(@invitee, :user, nil)
          render json: {
            token: token,
            user: { id: @invitee.id, email: @invitee.email, display_name: @invitee.display_name }
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join("、") }, status: :unprocessable_entity
        end

        private

        def set_no_index_headers
          response.headers["Cache-Control"] = "no-store"
          response.headers["X-Robots-Tag"] = "noindex, nofollow"
        end

        # トークン不一致・期限切れは 404。トークン自体はログに出さない(filter_parameter_logging の :token)。
        def set_invitee
          @invitee = User.find_signed(params[:token], purpose: :invitation)
          render(json: { error: "招待リンクが無効か、期限切れです" }, status: :not_found) unless @invitee
        end

        # 登録完了の確認メール。失敗しても登録は成功のまま(ログのみ)。
        def send_confirmation_mail
          UserProvisioning.send_registration_complete!(user: @invitee)
        rescue StandardError => e
          Rails.logger.error("[public/invitations#accept] 確認メール送信に失敗: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
