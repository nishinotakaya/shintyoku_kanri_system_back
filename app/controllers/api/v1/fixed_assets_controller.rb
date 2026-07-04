module Api
  module V1
    # 減価償却資産 (確定申告支援)。admin(西野)専用。
    class FixedAssetsController < BaseController
      before_action :require_admin

      def index
        year = params[:year].presence&.to_i || Date.current.year
        assets = current_user.fixed_assets.order(acquired_on: :desc)
        render json: assets.map { |a| serialize(a, year) }
      end

      def create
        asset = current_user.fixed_assets.create!(asset_params)
        render json: serialize(asset, Date.current.year), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def update
        asset = current_user.fixed_assets.find(params[:id])
        asset.update!(asset_params)
        render json: serialize(asset, params[:year].presence&.to_i || Date.current.year)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def destroy
        current_user.fixed_assets.find(params[:id]).destroy!
        head :no_content
      end

      private

      def require_admin
        return if current_user.can_use?(:keihi)
        render(json: { error: "経費計上の利用権限がありません" }, status: :forbidden)
      end

      def asset_params
        params.permit(:name, :acquired_on, :cost, :useful_life_years, :business_ratio, :memo)
      end

      def serialize(a, year)
        {
          id: a.id, name: a.name, acquired_on: a.acquired_on&.iso8601, cost: a.cost,
          useful_life_years: a.useful_life_years, business_ratio: a.business_ratio, memo: a.memo,
          depreciation_this_year: a.depreciation_for(year)
        }
      end
    end
  end
end
