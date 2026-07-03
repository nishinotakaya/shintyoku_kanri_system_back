module Api
  module V1
    # 川村さん等の Backlog 対応ログ（活動履歴）を月次で表示する管理ビュー。
    # 対象ユーザーのスコープ: admin=全員 / サブ管理者=managee / 一般=自分のみ。
    class BacklogActivitiesController < BaseController
      before_action :ensure_feature
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "対象が見つかりません" }, status: :not_found
      end

      # admin は常に可。非 admin は feature_flags["backlog_activities"] が ON なら自分のログを閲覧可。
      # 対象ユーザーの絞り込みは resolve_target_user(can_manage_user?) が別途担保する。
      def ensure_feature
        return if current_user.can_use?(:backlog_activities)
        render json: { error: "対応ログの利用権限がありません" }, status: :forbidden
      end

      # GET /api/v1/backlog_activities/targets  対象に選べるユーザー一覧（Backlog設定があるユーザー）
      def targets
        users = User.where(id: current_user.manageable_user_ids)
                    .joins(:backlog_setting).order(:id)
        counts = BacklogActivity.where(user_id: users.map(&:id)).group(:user_id).count
        render json: users.map { |u| user_brief(u).merge(activity_count: counts[u.id] || 0) }
      end

      # GET /api/v1/backlog_activities?user_id=  月次サマリ + 対応ログ詳細
      def index
        user = resolve_target_user or return
        render json: payload(user)
      end

      # POST /api/v1/backlog_activities/sync?user_id=  Backlog から取り直して保存
      def sync
        user = resolve_target_user or return
        synced = BacklogActivitySyncService.new(user).call
        render json: payload(user).merge(synced: synced)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/backlog_activities/export?user_id=  対応ログをスプレッドシートに書き出す
      def export
        user = resolve_target_user or return
        url = params[:spreadsheet_url].to_s.strip
        return render json: { error: "出力先スプレッドシートの URL を入力してください" }, status: :unprocessable_entity if url.empty?

        result = BacklogActivityExporter.new(user: user, operator: current_user, spreadsheet_url: url).call
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/backlog_activities/export_notion?user_id=
      # 西野・川村の Notion(WBS) タスクを Backlog とは別のスプレッドシートへ書き出す。
      def export_notion
        resolve_target_user or return # 閲覧権限の確認のみ（Notion タスクは西野・川村共通）
        url = params[:spreadsheet_url].to_s.strip
        return render json: { error: "Notion 出力先スプレッドシートの URL を入力してください" }, status: :unprocessable_entity if url.empty?

        result = NotionTaskExporter.new(operator: current_user, spreadsheet_url: url).call
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/backlog_activities/import_notion?user_id=
      # Notion(WBS) タブのスプレッドシートを読み、notion_tasks(修正後の値)を取り込む。
      def import_notion
        user = resolve_target_user or return
        url = params[:spreadsheet_url].to_s.strip
        return render json: { error: "Notion 取込元スプレッドシートの URL を入力してください" }, status: :unprocessable_entity if url.empty?

        result = NotionTaskImporter.new(operator: current_user, spreadsheet_url: url).call
        render json: payload(user).merge(notion_imported: result)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/backlog_activities/import?user_id=  スプシのサマリタブから備考/状態を取り込む
      def import
        user = resolve_target_user or return
        url = params[:spreadsheet_url].to_s.strip
        return render json: { error: "取込元スプレッドシートの URL を入力してください" }, status: :unprocessable_entity if url.empty?

        result = BacklogActivityImporter.new(user: user, operator: current_user, spreadsheet_url: url).call
        render json: payload(user).merge(imported: result)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/backlog_activities/note?user_id=  サマリ1行の備考/状態上書きを保存
      def update_note
        user = resolve_target_user or return
        note = user.backlog_summary_notes
                   .find_or_initialize_by(month: params.require(:month), issue_key: params.require(:issue_key))
        note.note = params[:note].to_s if params.key?(:note)
        note.status_override = params[:status_override].to_s if params.key?(:status_override)
        note.notion_block_id = params[:notion_block_id].presence if params.key?(:notion_block_id)
        note.save!
        render json: { ok: true, summary_rows: BacklogActivitySummary.new(user).rows }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/backlog_activities/notion_task?user_id=
      # Notion(WBS) タスクの「修正後」(prev 列) をアプリから手編集する。
      def update_notion_task
        resolve_target_user or return
        task = NotionTask.find_by(notion_block_id: params[:notion_block_id])
        return render json: { error: "Notion タスクが見つかりません" }, status: :not_found unless task

        task.start_date_prev    = date_param(params[:start_date_prev])    if params.key?(:start_date_prev)
        task.end_date_prev      = date_param(params[:end_date_prev])      if params.key?(:end_date_prev)
        task.progress_rate_prev = rate_param(params[:progress_rate_prev]) if params.key?(:progress_rate_prev)
        task.status_prev        = params[:status_prev].to_s.strip.presence if params.key?(:status_prev)
        task.memo               = params[:memo].to_s if params.key?(:memo)
        task.note               = params[:note].to_s if params.key?(:note) # 備考(Notion由来)の画面編集。次回同期でNotion値に戻る点は許容。
        task.save!
        render json: { ok: true, notion_tasks: notion_task_options }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def date_param(value)
        str = value.to_s.strip
        return nil if str.empty?
        Date.parse(str)
      rescue ArgumentError
        nil
      end

      def rate_param(value)
        str = value.to_s.delete("%").strip
        return nil if str.empty?
        num = str.to_f
        num > 1 ? num / 100.0 : num
      end

      def payload(user)
        {
          user: user_brief(user),
          summary: BacklogActivity.monthly_summary(user),
          summary_rows: BacklogActivitySummary.new(user).rows,
          status_legend: BacklogActivitySummary::STATUS_LEGEND,
          notion_tasks: notion_task_options,
          activities: user.backlog_activities.recent_first.map { |a| activity_payload(a) },
          synced_at: user.backlog_activities.maximum(:updated_at)
        }
      end

      # サマリ各行の「Notion」セレクト用の選択肢（西野・川村の WBS タスク）。
      # 紐付けると 開始日/完了予定日(予定) や 工数・進捗などを上司報告に取り込める。
      def notion_task_options
        NotionTask.order(:assignee_name, :wbs_level).map do |task|
          {
            notion_block_id: task.notion_block_id,
            assignee_name:   task.assignee_name,
            wbs_level:       task.wbs_level,
            title:           task.title,
            start_date:      task.start_date&.to_s,
            end_date:        task.end_date&.to_s,
            start_date_prev: task.start_date_prev&.to_s,
            end_date_prev:   task.end_date_prev&.to_s,
            workload:        task.workload&.to_f,
            progress_rate:   task.progress_rate&.to_f,
            progress_rate_prev: task.progress_rate_prev&.to_f,
            status:          task.status,
            status_prev:     task.status_prev,
            priority:        task.priority,
            note:            task.note.to_s,
            memo:            task.memo.to_s
          }
        end
      end

      def activity_payload(activity)
        {
          id:            activity.id,
          issue_key:     activity.issue_key,
          summary:       activity.summary,
          activity_type: activity.activity_type,
          type_label:    BacklogActivity::TYPE_LABELS[activity.activity_type],
          content:       activity.content,
          occurred_on:   activity.occurred_on,
          month:         activity.month,
          url:           activity.url
        }
      end

      def resolve_target_user
        target = params[:user_id].present? ? User.find(params[:user_id]) : default_target
        unless target && current_user.can_manage_user?(target.id)
          render json: { error: "このユーザーの対応ログを見る権限がありません" }, status: :forbidden
          return nil
        end
        target
      end

      # 既定の対象: assignee_name_filter が設定されたユーザー（＝川村さん）を優先
      def default_target
        manageable = current_user.manageable_user_ids
        BacklogSetting.where(user_id: manageable).where.not(assignee_name_filter: [ nil, "" ]).first&.user ||
          User.where(id: manageable).joins(:backlog_setting).order(:id).first ||
          current_user
      end

      def user_brief(user) = { id: user.id, display_name: user.display_name, email: user.email }
    end
  end
end
