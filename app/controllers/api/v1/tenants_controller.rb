module Api
  module V1
    # 自分が関わるテナント(会社)。代表は設定画面から会社名を変更できる。
    # 代表・メンバーの付け替えや code の変更は admin だけ(Api::V1::Admin::TenantsController)。
    class TenantsController < BaseController
      before_action :set_tenant, only: [ :update ]

      # GET /api/v1/tenants
      def index
        tenants = current_user.admin? ? Tenant.order(:id) : current_user.belonging_tenants.order(:id)
        render json: { tenants: tenants.map { |tenant| serialize(tenant) } }
      end

      # PATCH /api/v1/tenants/:id — 会社名だけ変更できる
      def update
        return render(json: { error: "この会社を編集する権限がありません" }, status: :forbidden) unless editable?(@tenant)

        @tenant.update!(params.permit(:name))
        render json: serialize(@tenant)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_tenant
        @tenant = Tenant.find(params[:id])
      end

      # 変更できるのは代表本人と admin だけ(メンバーは閲覧のみ)
      def editable?(tenant)
        current_user.admin? || tenant.owner_user_id == current_user.id
      end

      def serialize(tenant)
        {
          id: tenant.id, name: tenant.name, code: tenant.code,
          owner: tenant.owner_user && { id: tenant.owner_user.id, display_name: tenant.owner_user.display_name },
          members: tenant.member_users.map { |user| { id: user.id, display_name: user.display_name } },
          editable: editable?(tenant)
        }
      end
    end
  end
end
