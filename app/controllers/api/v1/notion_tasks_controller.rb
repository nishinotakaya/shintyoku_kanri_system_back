module Api
  module V1
    class NotionTasksController < BaseController
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
          synced_at: task.synced_at
        }
      end
    end
  end
end
