module Api
  module V1
    class TrelloTasksController < BaseController
      def index
        scope = TrelloTask.active
        scope = scope.for_date(parse_date) if params[:date].present? && params[:ignore_date] != "true"
        scope = scope.for_assignee(params[:assignee]) if params[:assignee].present?
        render json: scope.order(:position).map { |task| serialize(task) }
      end

      def sync
        count = TrelloSyncService.call(current_user)
        render json: { synced: count, at: Time.current.iso8601 }
      rescue TrelloClient::AuthError => e
        render json: { error: e.message }, status: :unauthorized
      rescue TrelloClient::ApiError => e
        render json: { error: e.message }, status: :bad_gateway
      end

      # PATCH /api/v1/trello_tasks/:id  { memo }
      # テックリーダーズタスクの手入力メモを更新する（リビングの notion_tasks#update と同じ役割）。
      def update
        task = TrelloTask.find(params[:id])
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
          trello_card_id: task.trello_card_id,
          title: task.title,
          description: task.description,
          list_name: task.list_name,
          board_name: task.board_name,
          assignee_name: task.assignee_name,
          start_date: task.start_date,
          due_date: task.due_date,
          url: task.url,
          memo: task.memo,
          synced_at: task.synced_at
        }
      end
    end
  end
end
