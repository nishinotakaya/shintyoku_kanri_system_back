module Api
  module V1
    class WorkReportsController < BaseController
      before_action :set_report, only: [ :update, :destroy ]

      def index
        year, month = parse_month
        target = viewing_user
        period = target.period_for(year, month)
        reports = target.work_reports.in_range(period)
        render json: {
          period: { from: period.first, to: period.last },
          reports: reports.map { |r| serialize(r) },
          viewing: { id: target.id, display_name: target.display_name }
        }
      end

      def create
        cat = params[:category].presence || "wings"
        report = viewing_user.work_reports.find_or_initialize_by(work_date: params[:work_date], category: cat)
        report.assign_attributes(report_params)
        report.save!
        sync_expense_from_report(report)
        render json: serialize(report), status: :created
      end

      def update
        @report.update!(report_params)
        sync_expense_from_report(@report)
        render json: serialize(@report)
      end

      def destroy
        @report.destroy!
        head :no_content
      end

      def clock_in
        cat = params[:category].presence || "wings"
        report = current_user.work_reports.find_or_initialize_by(work_date: Date.current, category: cat)
        report.clock_in ||= Time.current
        report.save!
        render json: serialize(report)
      end

      def clock_out
        cat = params[:category].presence || "wings"
        report = current_user.work_reports.find_or_initialize_by(work_date: Date.current, category: cat)
        report.clock_out = Time.current
        if report.clock_in && report.clock_out
          worked_min = ((report.clock_out - report.clock_in) / 60).to_i - report.break_minutes.to_i
          report.hours = (worked_min / 60.0).round(2) if worked_min.positive?
        end
        report.save!
        render json: serialize(report)
      end

      def voice_command
        parsed = WorkReportCommandParser.new(
          text: params[:text],
          user: current_user,
          base_date: Date.current,
          selected_range: params[:selected_range]
        ).call
        cat = params[:category].presence || "wings"
        applied = WorkReportBulkApplier.new(current_user, parsed[:ops], category: cat).call
        render json: { ops: parsed[:ops], applied: applied.map { |r| serialize(r) } }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def transcribe
        file = params[:audio]
        return render(json: { error: "audio missing" }, status: :bad_request) unless file
        text = OpenaiClient.transcribe(file.tempfile, user: current_user)
        render json: { text: text }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 設定保存時: 通勤日の全業務報告に乗車区間・交通費を一括反映 + 立替金も
      def apply_transit
        year, month = parse_month
        period = current_user.period_for(year, month)
        commute_days = (current_user.commute_days || [ 1, 2, 3, 4, 5 ]).map(&:to_i).to_set
        custom_off = (current_user.custom_off_days || []).map { |d| Date.parse(d) rescue nil }.compact.to_set
        from = current_user.default_transit_from
        to = current_user.default_transit_to
        fee = current_user.default_transit_fee
        line = current_user.default_transit_line
        cat = params[:category] || "wings"

        return render(json: { applied: 0 }) unless from.present? && fee.to_i > 0

        section = "#{from} ~ #{to}"
        count = 0

        ActiveRecord::Base.transaction do
          # 期間内の立替金を一旦全削除して再作成
          current_user.expenses.where(expense_date: period, category: cat).destroy_all

          period.each do |date|
            next if date.saturday? || date.sunday?
            next if custom_off.include?(date)

            if commute_days.include?(date.wday)
              wr = current_user.work_reports.find_or_initialize_by(work_date: date, category: cat)
              wr.transit_section = section
              wr.transit_fee = fee
              wr.save!

              expense = current_user.expenses.find_or_initialize_by(
                expense_date: date, category: cat, from_station: from, to_station: to
              )
              expense.purpose ||= "顧客先出張"
              expense.transport_type ||= "train"
              expense.round_trip = true if expense.round_trip.nil?
              expense.receipt_no ||= "無"
              expense.amount = fee
              expense.payee_or_line ||= line
              expense.save!

              count += 1
            else
              wr = current_user.work_reports.find_by(work_date: date, category: cat)
              wr&.update!(transit_section: nil, transit_fee: nil) if wr&.transit_fee.to_i > 0
            end
          end
        end

        render json: { applied: count }
      end

      def import_progress
        file = params[:file]
        return render(json: { error: "file missing" }, status: :bad_request) unless file
        year, month = parse_month
        cat = params[:category].presence || "wings"

        tmp = Rails.root.join("tmp", "progress_#{SecureRandom.hex(4)}.xlsx")
        File.open(tmp, "wb") { |f| f.write(file.read) }

        reports = ProgressImporter.new(
          user: current_user, file: tmp, year: year, month: month,
          daily_hours: params[:daily_hours]&.to_f || 7.5
        ).call

        if params[:apply] == "true"
          applied = []
          ActiveRecord::Base.transaction do
            reports.each do |r|
              wr = current_user.work_reports.find_or_initialize_by(work_date: r[:date], category: cat)
              wr.content = r[:content]
              wr.hours = r[:hours]
              wr.save!
              applied << serialize(wr)
            end
          end
          render json: { applied: applied, count: applied.size }
        else
          render json: { preview: reports, count: reports.size }
        end
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      ensure
        File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
      end

      # タスクを業務報告に追記（既存があれば追記、なければ作成）
      # params: work_date, category, issue_key, hours, target_assignee（省略時は current_user）
      def append_task
        target = resolve_target_user(params[:target_assignee])
        unless target == current_user || admin_user?(current_user)
          return render(json: { error: "他ユーザーへの追加権限がありません" }, status: :forbidden)
        end
        cat = params[:category].presence || "wings"
        issue_key = params[:issue_key].to_s
        hours = params[:hours].to_f
        report = target.work_reports.find_or_initialize_by(work_date: params[:work_date], category: cat)
        existing_content = report.content.to_s
        entry_str = hours > 0 ? "#{issue_key}(#{format_hours(hours)})" : issue_key
        report.content = existing_content.empty? ? entry_str : "#{existing_content}/#{entry_str}"
        report.hours = (report.hours.to_f + hours)
        report.save!
        render json: serialize(report).merge(target_user: target.display_name)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def admin_user?(user)
        user.display_name.to_s.include?("西野")
      end

      def resolve_target_user(target_assignee)
        return current_user if target_assignee.blank?
        surname = current_user.display_name.to_s.split(/[\s　]/).first.to_s
        return current_user if target_assignee.to_s.include?(surname) || surname.include?(target_assignee.to_s)
        User.where("display_name LIKE ?", "%#{target_assignee}%").first || current_user
      end

      def format_hours(h)
        h == h.to_i ? h.to_i.to_s : ("%.1f" % h)
      end

      def set_report
        # admin は他ユーザーの work_report も編集可（viewing_user 経由）
        @report = viewing_user.work_reports.find(params[:id])
      end

      # 乗車区間・交通費 → 立替金に自動同期（report の所属ユーザーで連動）
      def sync_expense_from_report(report)
        cat = report.category || "wings"
        owner = report.user

        if report.transit_section.present? && report.transit_fee.to_i > 0
          parts = report.transit_section.split(/\s*[~～〜\-\s]+/)
          from = parts[0].to_s.strip
          to = parts[1].to_s.strip

          expense = owner.expenses.find_or_initialize_by(
            expense_date: report.work_date, category: cat
          )
          expense.from_station = from
          expense.to_station = to
          expense.purpose ||= "顧客先出張"
          expense.transport_type ||= "train"
          expense.round_trip = true if expense.round_trip.nil?
          expense.receipt_no ||= "無"
          expense.amount = report.transit_fee
          expense.payee_or_line ||= owner.default_transit_line
          expense.save!
        else
          # 乗車区間が空になったら立替金も削除
          owner.expenses.where(expense_date: report.work_date, category: cat).destroy_all
        end
      end

      def report_params
        params.permit(:work_date, :content, :hours, :clock_in, :clock_out,
                      :break_minutes, :transit_section, :transit_fee, :category)
      end

      def serialize(r)
        {
          id: r.id, work_date: r.work_date, content: r.content,
          hours: r.hours&.to_f, clock_in: r.clock_in&.strftime("%H:%M"),
          clock_out: r.clock_out&.strftime("%H:%M"),
          break_minutes: r.break_minutes,
          transit_section: r.transit_section, transit_fee: r.transit_fee,
          category: r.category
        }
      end
    end
  end
end
