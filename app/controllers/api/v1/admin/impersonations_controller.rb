module Api
  module V1
    module Admin
      # 管理者が他ユーザーとしてログインする(なりすまし)。
      # 対象ユーザーの JWT を発行して返すだけで、権限判定はすべて通常どおりそのユーザーとして行われる。
      # 誰が誰になりすましたかは必ずログに残す。
      class ImpersonationsController < BaseController
        before_action :ensure_admin

        # POST /api/v1/admin/impersonations { user_id: }
        def create
          target = User.find_by(id: params[:user_id])
          return render(json: { error: "ユーザーが見つかりません" }, status: :not_found) if target.nil?
          return render(json: { error: "自分にはなりすませません" }, status: :unprocessable_entity) if target.id == current_user.id

          token, _payload = Warden::JWTAuth::UserEncoder.new.call(target, :user, nil)
          Rails.logger.warn(
            "[impersonation] admin=#{current_user.id}(#{current_user.email}) -> user=#{target.id}(#{target.email})"
          )

          render json: {
            token: token,
            user: { id: target.id, display_name: target.display_name, email: target.email },
            admin: { id: current_user.id, display_name: current_user.display_name }
          }
        end

        private

        def ensure_admin
          render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        end
      end
    end
  end
end
