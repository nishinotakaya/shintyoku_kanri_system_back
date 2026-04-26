module Api
  module V1
    class MonthlySettingsController < BaseController
      def show
        year, month = parse_month
        s = MonthlySetting.find_or_initialize_for(current_user, year, month)
        render json: serialize(s, year, month)
      end

      def update
        year, month = parse_month
        s = MonthlySetting.find_or_initialize_for(current_user, year, month)
        s.application_date = params[:application_date].presence
        s.save!
        render json: serialize(s, year, month)
      end

      private

      def serialize(s, year, month)
        {
          year: year,
          month: month,
          application_date: s.application_date&.iso8601,
          default_application_date: Date.current.iso8601
        }
      end
    end
  end
end
