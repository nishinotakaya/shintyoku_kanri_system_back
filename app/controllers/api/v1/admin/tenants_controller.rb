module Api
  module V1
    module Admin
      # admin がテナント(会社)を作成・編集するためのコントローラ。
      # 代表(owner_user_id)とメンバー(member_user_ids)を紐付けて管理する。
      class TenantsController < BaseController
        before_action :ensure_admin
        before_action :set_tenant, only: [ :update, :destroy ]

        # GET /api/v1/admin/tenants
        def index
          tenants = Tenant.order(:id).includes(:owner_user, :member_users)
          render json: { tenants: tenants.map { |tenant| serialize(tenant) } }
        end

        # POST /api/v1/admin/tenants
        # params: name, code, owner_user_id, member_user_ids
        def create
          tenant = Tenant.new(tenant_params)
          tenant.save!
          assign_members(tenant)
          render json: serialize(tenant.reload), status: :created
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/tenants/:id
        def update
          @tenant.update!(tenant_params)
          assign_members(@tenant) if params.key?(:member_user_ids)
          render json: serialize(@tenant.reload)
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # DELETE /api/v1/admin/tenants/:id
        def destroy
          @tenant.destroy!
          head :no_content
        end

        private

        def set_tenant
          @tenant = Tenant.find(params[:id])
        end

        def tenant_params
          params.permit(:name, :code, :owner_user_id)
        end

        # 配列は permit を通さないと取り出せない(params[:member_user_ids] だけでは nil になる)
        def assign_members(tenant)
          ids = params.permit(member_user_ids: [])[:member_user_ids]
          return unless ids

          member_ids = Array(ids).map(&:to_i).reject(&:zero?).uniq
          tenant.tenant_memberships.where.not(user_id: member_ids).destroy_all
          member_ids.each do |user_id|
            tenant.tenant_memberships.find_or_create_by!(user_id: user_id)
          end
        end

        def serialize(tenant)
          {
            id: tenant.id, name: tenant.name, code: tenant.code,
            owner: tenant.owner_user && { id: tenant.owner_user.id, display_name: tenant.owner_user.display_name },
            members: tenant.member_users.map { |user| { id: user.id, display_name: user.display_name } }
          }
        end

        def ensure_admin
          render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        end
      end
    end
  end
end
