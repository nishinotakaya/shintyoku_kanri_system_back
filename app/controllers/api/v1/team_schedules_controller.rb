module Api
  module V1
    class TeamSchedulesController < BaseController
      def index
        year, month = parse_month_param
        year_month = format("%04d%02d", year, month)
        records = TeamSchedule.where(year_month: year_month).order(:date, :person)
        render json: records.map { |record|
          {
            id: record.id,
            date: record.date.iso8601,
            person: record.person,
            status: record.status,
            location: record.location,
            memo: record.memo
          }
        }
      end

      def import
        year, month = parse_month_param
        result = TeamScheduleImporter.new(user: current_user, year: year, month: month).call
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def parse_month_param
        month_str = params[:month].presence || Date.current.strftime("%Y-%m")
        year_str, month_part = month_str.split("-")
        [year_str.to_i, month_part.to_i]
      end
    end
  end
end
