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
    end
  end
end
