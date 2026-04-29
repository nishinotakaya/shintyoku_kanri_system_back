module Api
  module V1
    class BacklogController < BaseController
      def show_setting
        s = current_user.backlog_setting || current_user.build_backlog_setting(BacklogSetting::DEFAULTS)
        render json: serialize_setting(s)
      end

      def update_setting
        s = current_user.backlog_setting || current_user.build_backlog_setting(BacklogSetting::DEFAULTS)
        s.assign_attributes(setting_params)
        s.save!
        render json: serialize_setting(s)
      end

      def test_connection
        s = current_user.backlog_setting
        return render(json: { success: false, error: "設定が未保存です" }) unless s

        client = BacklogClient.new(s)
        result = client.test_connection
        render json: result
      end

      def sync
        result = BacklogSyncService.new(current_user).call
        render json: {
          synced: result.size,
          tasks: result.map { |t| serialize_task(t) }
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def reorder
        ids = params[:ids] || []
        ids.each_with_index do |id, i|
          current_user.backlog_tasks.where(id: id).update_all(position: i)
        end
        head :ok
      end

      def update_task
        task = current_user.backlog_tasks.find(params[:id])
        permitted = params.permit(:memo, :summary, :start_date, :end_date, :status_id, :progress_value, :deploy_date, :deploy_note, :url, :assignee_name, :did_previous, :do_today)
        if permitted[:status_id].present?
          permitted[:status_name] = BacklogTask::STATUS_NAMES[permitted[:status_id].to_i]
          if permitted[:status_id].to_i == 4 && task.completed_on.nil?
            permitted[:completed_on] = Date.current
          elsif permitted[:status_id].to_i != 4
            permitted[:completed_on] = nil
          end
        end
        task.update!(permitted)
        render json: serialize_task(task)
      end

      def create_task
        task = current_user.backlog_tasks.create!(
          issue_key: "LOCAL-#{SecureRandom.hex(3).upcase}",
          summary: params[:summary],
          status_id: 1,
          status_name: "未対応",
          created_on: Date.current,
          memo: params[:memo],
          due_date: params[:due_date],
          deploy_note: params[:deploy_note],
          url: params[:url].presence || params[:deploy_note],
          assignee_name: current_user.display_name,
          source: "local"
        )
        render json: serialize_task(task), status: :created
      end

      def destroy_task
        current_user.backlog_tasks.find(params[:id]).destroy!
        head :no_content
      end

      def sync_to_work_reports
        year, month = parse_month
        svc = BacklogToWorkReportService.new(
          user: current_user,
          year: year,
          month: month,
          category: params[:category] || "wings",
          daily_hours: params[:daily_hours]&.to_f || 8.0
        )
        applied = svc.apply!
        render json: { applied: applied.size }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def import_sheet
        url = params[:spreadsheet_url]
        sheet = params[:sheet_name].presence
        return render(json: { error: "スプレッドシートURLを入力してください" }, status: :bad_request) unless url.present?

        result = GoogleSheetsImporter.new(user: current_user, spreadsheet_url: url, sheet_name: sheet).call
        render json: { imported: result[:imported], sheets: result[:sheets] }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def export_sheet
        url = params[:spreadsheet_url]
        return render(json: { error: "スプレッドシートURLを入力してください" }, status: :bad_request) unless url.present?

        result = GoogleSheetsExporter.new(user: current_user, spreadsheet_url: url).call
        render json: { success: true, active: result[:active], completed: result[:completed] }
      rescue => e
        body = e.respond_to?(:body) ? e.body.to_s : ""
        app_trace = (e.backtrace || []).select { |l| l.include?("/app/") }.first(15)
        Rails.logger.error("[backlog#export_sheet] #{e.class}: #{e.message}\nBODY: #{body}\nAPP TRACE:\n#{app_trace.join("\n")}")
        render json: { error: "#{e.class}: #{e.message}\n#{body}" }, status: :unprocessable_entity
      end

      def sheet_tabs
        url = params[:spreadsheet_url]
        return render(json: { error: "URLを入力してください" }, status: :bad_request) unless url.present?

        sheets = GoogleSheetsImporter.new(user: current_user, spreadsheet_url: url).list_sheets
        render json: { sheets: sheets }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def tasks
        tasks = current_user.backlog_tasks.order(:status_id, Arel.sql("COALESCE(position, 9999)"), :issue_key)
        # ステータスでフィルタ
        if params[:status_ids].present?
          ids = params[:status_ids].split(",").map(&:to_i)
          tasks = tasks.by_status(ids)
        end
        render json: tasks.map { |t| serialize_task(t) }
      end

      # 指定日に活動中だったタスクを返す（完了以外で、計画/実績期間が当日を覆う）
      # assignee 指定で担当者名で絞り込み
      def task_comments
        task = current_user.backlog_tasks.find_by!(issue_key: params[:issue_key])
        s = current_user.backlog_setting
        return render(json: { error: "Backlog 設定が未保存です" }, status: :bad_request) unless s&.api_key.present?
        comments = BacklogClient.new(s).fetch_comments(task.issue_key)
        render json: comments.map { |c|
          {
            id: c["id"],
            content: c["content"],
            created_user_name: c.dig("createdUser", "name"),
            created: c["created"],
            updated: c["updated"]
          }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "タスクが見つかりません" }, status: :not_found
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def tasks_on_date
        target_date = Date.iso8601(params[:date].to_s)
        recent_completed_threshold = target_date - 3
        scope = viewing_user.backlog_tasks
          .where(
            "(status_id <> 4 AND ((start_date IS NULL OR start_date <= ?) AND (end_date IS NULL OR end_date >= ?) OR " \
            "(created_on IS NULL OR created_on <= ?) AND (completed_on IS NULL OR completed_on >= ?))) " \
            "OR (status_id = 4 AND completed_on IS NOT NULL AND completed_on >= ? AND completed_on <= ?)",
            target_date, target_date, target_date, target_date,
            recent_completed_threshold, target_date
          )
        if params[:assignee].present?
          scope = scope.where("assignee_name LIKE ?", "%#{params[:assignee]}%")
        end
        # 表示順: 処理済(3) → 処理中(2) → 未対応(1) → 完了(4) → その他
        status_order = Arel.sql("CASE status_id WHEN 3 THEN 1 WHEN 2 THEN 2 WHEN 1 THEN 3 WHEN 4 THEN 4 ELSE 5 END")
        render json: scope.order(status_order, Arel.sql("COALESCE(position, 9999)"), :issue_key).map { |t| serialize_task(t) }
      rescue ArgumentError
        render json: { error: "date パラメータが不正です" }, status: :bad_request
      end

      private

      def setting_params
        params.require(:backlog_setting).permit(
          :backlog_url, :backlog_email, :backlog_password, :board_id, :user_backlog_id, :session_cookie, :api_key, :assignee_name_filter
        )
      end

      def serialize_setting(s)
        {
          backlog_url: s.backlog_url,
          backlog_email: s.backlog_email,
          has_password: s.backlog_password.present?,
          board_id: s.board_id,
          user_backlog_id: s.user_backlog_id,
          has_cookie: s.session_cookie.present?,
          has_api_key: s.api_key.present?,
          assignee_name_filter: s.assignee_name_filter
        }
      end

      def serialize_task(t)
        {
          id: t.id, issue_key: t.issue_key, summary: t.summary,
          status_id: t.status_id, status_name: t.status_name,
          progress: t.progress,
          created_on: t.created_on, completed_on: t.completed_on,
          start_date: t.start_date, end_date: t.end_date, due_date: t.due_date,
          memo: t.memo, position: t.position,
          deploy_date: t.deploy_date, deploy_note: t.deploy_note,
          source: t.source, assignee_name: t.assignee_name, assignee_id: t.assignee_id,
          url: t.url,
          did_previous: t.did_previous, do_today: t.do_today
        }
      end
    end
  end
end
