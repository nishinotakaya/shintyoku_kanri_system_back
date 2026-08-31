module Api
  module V1
    class ProgressWorkspacesController < BaseController
      before_action :set_progress_workspace, only: [ :update, :destroy ]

      # 権限の無い外部データソース(Wing/リビング/テックリーダーズ)のワークスペースは返さない。
      # フロントはこの一覧でタブを描くので、権限が無いソースはタブごと消える。
      def index
        ProgressWorkspace.ensure_defaults!(current_user)
        hidden_source_types = current_user.hidden_data_source_types
        workspaces = current_user.progress_workspaces.order(:position, :id)
          .reject { |workspace| hidden_source_types.include?(workspace.source_type) }
        render json: workspaces.map(&:as_payload)
      end

      def create
        source_type = params[:source_type].presence || "manual"
        return render(json: { error: "source_type が不正です" }, status: :unprocessable_entity) unless ProgressWorkspace::SOURCE_TYPES.include?(source_type)
        return render(json: { error: "このデータソースを扱う権限がありません" }, status: :forbidden) if current_user.hidden_data_source_types.include?(source_type)

        next_position = (current_user.progress_workspaces.maximum(:position) || -1) + 1
        workspace = current_user.progress_workspaces.create!(
          name: params[:name],
          source_type: source_type,
          builtin: false,
          position: next_position
        )
        render json: workspace.as_payload, status: :created
      end

      def update
        # 名前とスプレッドシートURLはそれぞれ単独でも更新できるようにする
        # (URLだけ保存したいときに name を送らずに済ませる)。
        attributes = {}
        attributes[:name] = params[:name] if params.key?(:name)
        attributes[:sheet_url] = params[:sheet_url].to_s.strip.presence if params.key?(:sheet_url)
        @progress_workspace.update!(attributes) if attributes.any?
        render json: @progress_workspace.as_payload
      end

      def destroy
        if @progress_workspace.builtin?
          return render(json: { error: "デフォルトのワークスペースは削除できません" }, status: :unprocessable_entity)
        end
        if @progress_workspace.backlog_tasks.exists?
          return render(json: { error: "タスクが残っています。先にタスクを移動/削除してください" }, status: :unprocessable_entity)
        end

        @progress_workspace.destroy!
        head :no_content
      end

      private

      def set_progress_workspace
        @progress_workspace = current_user.progress_workspaces.find(params[:id])
      end
    end
  end
end
