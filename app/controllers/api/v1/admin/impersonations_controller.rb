module Api
  module V1
    module Admin
      # 管理者・サブ管理者(テナント代表等)が他ユーザーとしてログインする(なりすまし)。
      # 範囲: 管理者=全ユーザー / サブ管理者=管理対象(manageable_user_ids。例: 雄太郎→運送外注 太郎)。
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
          users = impersonation_candidates.where.not(id: acting_admin.id).order(:id)
          render json: users.map { |user| user_json(user) }
        end

        # POST /api/v1/admin/impersonations { user_id: }
        def create
          target = User.find_by(id: params[:user_id])
          return render(json: { error: "ユーザーが見つかりません" }, status: :not_found) if target.nil?
          return render(json: { error: "自分にはなりすませません" }, status: :unprocessable_entity) if target.id == acting_admin.id
          unless can_impersonate?(target)
            return render(json: { error: "このユーザーへのなりすまし権限がありません" }, status: :forbidden)
          end

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

        # なりすましを操作できる主体。素の管理者/サブ管理者か、なりすまし中ならその発行元。
        def acting_admin
          @acting_admin ||= impersonator || current_user
        end

        def ensure_impersonation_allowed
          return if acting_admin&.admin? || acting_admin&.sub_admin?
          render(json: { error: "admin またはサブ管理者のみ利用できます" }, status: :forbidden)
        end

        def impersonation_candidates
          acting_admin.admin? ? User.all : User.where(id: acting_admin.manageable_user_ids)
        end

        def can_impersonate?(target)
          acting_admin.admin? || acting_admin.can_manage_user?(target.id)
        end

        def user_json(user)
          { id: user.id, display_name: user.display_name, email: user.email }
        end
      end
    end
  end
end
