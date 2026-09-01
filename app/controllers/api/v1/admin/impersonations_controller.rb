module Api
  module V1
    module Admin
      # 管理者が他ユーザーとしてログインする(なりすまし)。
      #
      # 発行するトークンに impersonator_id を埋め込むので、
      #   - ブラウザの localStorage が消えても管理者に戻れる(詰まない)
      #   - なりすまし中のまま別ユーザーへ乗り換えられる(いちいち管理者に戻らなくてよい)
      # 一方で権限判定は対象ユーザー本人のものを使うため、「その人にどう見えるか」は正しく再現される。
      class ImpersonationsController < BaseController
        before_action :ensure_impersonation_allowed

        # GET /api/v1/admin/impersonations
        # なりすまし先の候補。なりすまし中でも呼べるので、バナーの切替セレクトに使える。
        def index
          users = User.where.not(id: acting_admin.id).order(:id)
          render json: users.map { |user| user_json(user) }
        end

        # POST /api/v1/admin/impersonations { user_id: }
        def create
          target = User.find_by(id: params[:user_id])
          return render(json: { error: "ユーザーが見つかりません" }, status: :not_found) if target.nil?
          return render(json: { error: "自分にはなりすませません" }, status: :unprocessable_entity) if target.id == acting_admin.id

          Rails.logger.warn(
            "[impersonation] start admin=#{acting_admin.id}(#{acting_admin.email}) -> user=#{target.id}(#{target.email})"
          )
          render json: {
            token: target.issue_jwt(impersonated_by: acting_admin),
            user: user_json(target),
            admin: user_json(acting_admin)
          }
        end

        # DELETE /api/v1/admin/impersonations
        # 提示されたなりすましトークンだけを根拠に、管理者アカウントのトークンを再発行する。
        def destroy
          return render(json: { error: "なりすまし中ではありません" }, status: :unprocessable_entity) if impersonator.nil?

          Rails.logger.warn("[impersonation] stop admin=#{impersonator.id} <- user=#{current_user.id}")
          render json: { token: impersonator.issue_jwt, user: user_json(impersonator) }
        end

        private

        # なりすましを操作できる主体。素の管理者か、管理者がなりすまし中ならその管理者。
        def acting_admin
          @acting_admin ||= impersonator || current_user
        end

        def ensure_impersonation_allowed
          render(json: { error: "admin only" }, status: :forbidden) unless acting_admin&.admin?
        end

        def user_json(user)
          { id: user.id, display_name: user.display_name, email: user.email }
        end
      end
    end
  end
end
