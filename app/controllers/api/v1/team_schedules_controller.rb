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
        # 今日基準で前月・当月・翌月の 3 シートを処理
        results = []
        total_imported = 0
        target_year_months.each do |y, m|
          begin
            r = TeamScheduleImporter.new(user: current_user, year: y, month: m).call
            results << r
            total_imported += r[:imported].to_i
          rescue => e
            results << { sheet: format("%04d%02d", y, m), error: e.message }
          end
        end
        render json: { imported: total_imported, persons: TeamScheduleImporter::PERSONS, sheets: results }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def export
        results = []
        total_updated = 0
        target_year_months.each do |y, m|
          begin
            r = TeamScheduleExporter.new(user: current_user, year: y, month: m).call
            results << r
            total_updated += r[:updated].to_i
          rescue => e
            results << { sheet: format("%04d%02d", y, m), error: e.message }
          end
        end
        render json: { updated: total_updated, sheets: results }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def update
        record = TeamSchedule.find(params[:id])
        record.update!(params.permit(:status, :location, :memo))
        render json: serialize_record(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/team_schedules/sync_expenses
      # 取り込み済みの team_schedules から、出社日に交通費 Expense を一括作成する。
      # 既存の Expense は上書きしない (idempotent)。
      def sync_expenses
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        results = []
        total = 0
        target_year_months.each do |y, m|
          TeamScheduleImporter::PERSONS.each do |person_name|
            target = User.where("display_name LIKE ?", "%#{person_name}%").find_each.find { |u| !u.display_name.to_s.start_with?("wing") }
            next unless target
            created = TeamScheduleExpenseSync.new(user: target, year: y, month: m).call
            total += created.size
            results << { year: y, month: m, person: person_name, created: created.size }
          end
        end
        render json: { created: total, details: results }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def create
        date = Date.iso8601(params[:date].to_s)
        record = TeamSchedule.find_or_initialize_by(date: date, person: params[:person].to_s)
        record.assign_attributes(
          status: params[:status].to_s,
          year_month: date.strftime("%Y%m")
        )
        record.save!
        render json: serialize_record(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def serialize_record(record)
        {
          id: record.id,
          date: record.date.iso8601,
          person: record.person,
          status: record.status,
          location: record.location,
          memo: record.memo
        }
      end

      def parse_month_param
        month_str = params[:month].presence || Date.current.strftime("%Y-%m")
        year_str, month_part = month_str.split("-")
        [ year_str.to_i, month_part.to_i ]
      end

      # 今日基準で前月・当月・翌月の [年, 月] を返す
      def target_year_months
        today = Date.current
        prev_d = today.prev_month
        next_d = today.next_month
        [
          [ prev_d.year, prev_d.month ],
          [ today.year,  today.month ],
          [ next_d.year, next_d.month ]
        ]
      end
    end
  end
end
