module Api
  module V1
    class BaseController < ApplicationController
      before_action :authenticate_user!

      private

      def parse_month
        if params[:month].present?
          y, m = params[:month].split("-").map(&:to_i)
          [ y, m ]
        else
          today = Date.current
          [ today.year, today.month ]
        end
      end

      def parse_application_date
        Date.iso8601(params[:application_date]) if params[:application_date].present?
      end

      # 管理者は params[:as_user_id] で他ユーザーとして閲覧可能。
      # それ以外は常に current_user。
      def viewing_user
        return @viewing_user if defined?(@viewing_user)
        @viewing_user =
          if current_user.admin? && params[:as_user_id].present?
            User.find_by(id: params[:as_user_id]) || current_user
          else
            current_user
          end
      end
    end
  end
end
