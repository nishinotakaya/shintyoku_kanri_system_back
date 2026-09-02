module Api
  module V1
    class NotionTasksController < BaseController
      # リビングは全ユーザー共通の1テーブルなので、権限のある人だけに開ける
      before_action -> { require_data_source!("notion", :view) }, only: [ :index, :line_report_preview, :line_report ]
      before_action -> { require_data_source!("notion", :sync) }, only: :sync
      before_action -> { require_data_source!("notion", :write) }, only: :update

      def index
        scope = NotionTask.active
        scope = scope.for_date(parse_date) if params[:date].present? && params[:ignore_date] != "true"
        scope = scope.for_assignee(params[:assignee]) if params[:assignee].present?
        render json: scope.order(:start_date, :wbs_level).map { |task| serialize(task) }
      end

      def sync
        count = NotionSyncService.call
        render json: { synced: count, at: Time.current.iso8601 }
      rescue NotionClient::AuthError => e
        render json: { error: e.message }, status: :unauthorized
      rescue NotionClient::ApiError => e
        render json: { error: e.message }, status: :bad_gateway
      end

      # POST /api/v1/notion_tasks/line_report_preview  { issue_keys: ["N-..."] }
      # 進捗カンバン(リビング)で選んだタスクの LINE 報告文面を組み立てて返す。送信はしない。
      def line_report_preview
        tasks = NotionTask.for_kanban_issue_keys(params[:issue_keys]).order(:wbs_level, :start_date)
        return render(json: { error: "対象タスクが見つかりません" }, status: :unprocessable_entity) if tasks.empty?
        render json: { message: NotionLineReport.new(tasks, reporter: current_user.display_name).message, task_count: tasks.size }
      end

      # POST /api/v1/notion_tasks/line_report  { issue_keys: ["N-..."], message?: string }
      # 文面(編集済みならその内容)を西野さんの LINE (LINE_PUSH_TO) に送信する。
      # 送信後は *_prev(前回同期からの変更差分)をクリアし、次回の報告では変更なし扱いにする。
      def line_report
        tasks = NotionTask.for_kanban_issue_keys(params[:issue_keys]).order(:wbs_level, :start_date)
        return render(json: { error: "対象タスクが見つかりません" }, status: :unprocessable_entity) if tasks.empty?
        text = params[:message].to_s.strip.presence || NotionLineReport.new(tasks, reporter: current_user.display_name).message
        unless LineNotifier.push(text)
          return render(json: { error: "LINE送信に失敗しました。LINE設定(チャネルトークン)を確認してください" }, status: :bad_gateway)
        end
        tasks.each(&:clear_reported_diffs!)
        archive = LineReportArchiver.record(user: current_user, message: text)
        render json: { sent: true, task_count: tasks.size }.merge(archive)
      end

      # PATCH /api/v1/notion_tasks/:id  { memo }
      # リビングタスクの手入力メモを更新する（タマの backlog#update と同じ役割）。
      def update
        task = NotionTask.find(params[:id])
        task.update!(memo: params[:memo].to_s)
        render json: serialize(task)
      end

      private

      def parse_date
        Date.parse(params[:date])
      rescue ArgumentError, TypeError
        nil
      end

      def serialize(task)
        {
          id: task.id,
          notion_block_id: task.notion_block_id,
          wbs_level: task.wbs_level,
          title: task.title,
          parent_task: task.parent_task,
          assignee_name: task.assignee_name,
          start_date: task.start_date,
          end_date: task.end_date,
          workload: task.workload&.to_f,
          progress_rate: task.progress_rate&.to_f,
          status: task.status,
          priority: task.priority,
          note: task.note,
          memo: task.memo,
          url: task.url,
          # 前回同期からの変更差分(修正前の値)。LINE 報告の「修正前 → 修正後」表示に使う
          start_date_prev: task.start_date_prev,
          end_date_prev: task.end_date_prev,
          progress_rate_prev: task.progress_rate_prev&.to_f,
          status_prev: task.status_prev,
          synced_at: task.synced_at
        }
      end
    end
  end
end
