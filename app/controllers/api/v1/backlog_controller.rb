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

      # POST /api/v1/backlog/sync_notion
      # NotionTask 全件を builtin の「リビング」ワークスペースへ upsert する。
      def sync_notion
        synced = NotionTaskSyncService.new(current_user).call
        render json: { synced: synced }
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
        # ワークスペース間のタスク移動 (ワークスペース削除前の退避などで使う)
        permitted[:progress_workspace_id] = params[:workspace_id] if params[:workspace_id].present?
        if permitted[:status_id].present?
          permitted[:status_name] = BacklogTask::STATUS_NAMES[permitted[:status_id].to_i]
          if permitted[:status_id].to_i == 4 && task.completed_on.nil?
            permitted[:completed_on] = Date.current
          elsif permitted[:status_id].to_i != 4
            permitted[:completed_on] = nil
          end
        end
        task.update!(permitted)
        push_to_calendar(task) # プライベートTodoのみGoogleカレンダーへ反映
        render json: serialize_task(task)
      end

      def create_task
        attrs = {
          issue_key: "LOCAL-#{SecureRandom.hex(3).upcase}",
          summary: params[:summary],
          status_id: 1,
          status_name: "未対応",
          created_on: Date.current,
          memo: params[:memo],
          due_date: params[:due_date].presence,
          deploy_note: params[:deploy_note],
          url: params[:url].presence || params[:deploy_note],
          assignee_name: params[:assignee_name].presence || current_user.display_name,
          source: "local"
        }
        # カレンダーから日付指定で作る場合は start_date/end_date を渡してその日だけ表示
        attrs[:start_date] = params[:start_date] if params[:start_date].present?
        attrs[:end_date]   = params[:end_date]   if params[:end_date].present?
        attrs[:progress_workspace_id] = params[:workspace_id] if params[:workspace_id].present?
        task = current_user.backlog_tasks.create!(attrs)
        push_to_calendar(task) # プライベートTodoのみGoogleカレンダーへ反映
        render json: serialize_task(task), status: :created
      end

      def destroy_task
        task = current_user.backlog_tasks.find(params[:id])
        remove_from_calendar(task) # プライベートTodoならカレンダー側の予定も消す
        task.destroy!
        head :no_content
      end

      # プライベートワークスペースのTodo ⇄ 専用Googleカレンダーの取込。
      def import_calendar
        workspace = private_workspace
        return render(json: { error: "プライベートワークスペースが見つかりません" }, status: :not_found) unless workspace

        imported = GoogleCalendarSync.new(current_user).import(workspace)
        render json: { imported: imported }
      rescue GoogleCalendarSync::ScopeError => e
        Rails.logger.warn("[backlog#import_calendar] scope error: #{e.message}")
        render json: { error: "Googleカレンダーの権限がありません。一度ログアウトして再度Googleログインしてください。" }, status: :forbidden
      rescue => e
        Rails.logger.error("[backlog#import_calendar] #{e.class}: #{e.message}")
        render json: { error: e.message }, status: :unprocessable_entity
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

        result = GoogleSheetsImporter.new(
          user: current_user,
          spreadsheet_url: url,
          sheet_name: sheet,
          only_flagged: params[:only_flagged].to_s == "true"
        ).call
        render json: { imported: result[:imported], sheets: result[:sheets] }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def export_sheet
        url = params[:spreadsheet_url]
        return render(json: { error: "スプレッドシートURLを入力してください" }, status: :bad_request) unless url.present?

        result = GoogleSheetsExporter.new(
          user: current_user,
          spreadsheet_url: url,
          only_flagged: params[:only_flagged].to_s == "true"
        ).call
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
        # ワークスペースでフィルタ (未指定時は従来どおり全件=後方互換)
        tasks = tasks.where(progress_workspace_id: params[:workspace_id]) if params[:workspace_id].present?
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
        render json: comments.map { |c| serialize_comment(c) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "タスクが見つかりません" }, status: :not_found
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/backlog/tasks/:issue_key/comments
      # body: { content: "...", notified_user_ids: [...], attachment_ids: [...] }
      def create_task_comment
        task = current_user.backlog_tasks.find_by!(issue_key: params[:issue_key])
        s = current_user.backlog_setting
        return render(json: { error: "Backlog 設定が未保存です" }, status: :bad_request) unless s&.api_key.present?
        content = params.require(:content)
        notified = (params[:notified_user_ids] || []).map(&:to_i)
        atts = (params[:attachment_ids] || []).map(&:to_i)
        c = BacklogClient.new(s).add_comment(task.issue_key, content: content, notified_user_ids: notified, attachment_ids: atts)
        render json: serialize_comment(c), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/backlog/ai_polish
      # body: { content: "...", instruction: "..." (任意) }
      # OpenAI に通して markdown 整形 / 文章添削した本文を返す。
      def ai_polish
        content = params.require(:content)
        instruction = params[:instruction].to_s
        api_key = OpenaiClient.api_key_for(current_user)
        return render(json: { error: "OpenAI API キーが未設定です。設定画面で登録してください。" }, status: :bad_request) if api_key.blank?

        sys = <<~SYS
          あなたは Backlog コメントの添削アシスタントです。以下を 1 回の応答で全て行ってください。
          1. 誤字脱字を修正
          2. 文章を丁寧で読みやすい日本語に整える (主語/てにをは/語尾を統一)
          3. 適切な箇所を markdown 化:
             - 見出し (# / ## / ###)、箇条書き (- )、表 (| 列 | 列 |)、コードブロック (```)、強調 (**), インラインコード (`)
             - URL は markdown リンクや生 URL のまま (自動でリンク化される)
             - メンション (@名前) は壊さない
             - 〔M0〕〔M1〕… のような 〔…〕 で囲まれたトークンは絶対にそのまま (改変・削除・翻訳・装飾せず) 残す
          4. 元から markdown があれば尊重して維持
          5. 文意は絶対に変えない (要約しない)
          出力は本文のみ。"承知しました" 等の前置き、コードフェンスでの全体ラップは不要。
        SYS
        user_msg = instruction.present? ? "指示: #{instruction}\n\n本文:\n#{content}" : content

        uri = URI("https://api.openai.com/v1/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.read_timeout = 60 }
        req = Net::HTTP::Post.new(uri.path)
        req["Content-Type"] = "application/json"
        req["Authorization"] = "Bearer #{api_key}"
        req.body = {
          model: ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"),
          messages: [
            { role: "system", content: sys },
            { role: "user", content: user_msg }
          ],
          temperature: 0.3
        }.to_json
        res = http.request(req)
        return render(json: { error: "OpenAI エラー (#{res.code}): #{res.body.to_s.slice(0, 200)}" }, status: :bad_request) unless res.code.start_with?("2")
        result = JSON.parse(res.body).dig("choices", 0, "message", "content").to_s.strip
        # コードフェンスで全体を囲まれる場合は剥がす
        if result.start_with?("```") && result.end_with?("```")
          result = result.sub(/\A```[a-zA-Z]*\n/, "").sub(/\n```\z/, "")
        end
        render json: { content: result }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/backlog/attachments
      # multipart file アップロード → Backlog Space attachment 登録 → id 返却
      def create_attachment
        file = params[:file]
        return render(json: { error: "ファイルを添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)
        s = current_user.backlog_setting
        return render(json: { error: "Backlog 設定が未保存です" }, status: :bad_request) unless s&.api_key.present?
        io = file.tempfile.presence || file
        io.rewind if io.respond_to?(:rewind)
        content = io.read
        result = BacklogClient.new(s).upload_attachment(
          filename: file.original_filename,
          content_type: (file.respond_to?(:content_type) ? file.content_type : nil),
          content: content
        )
        render json: { id: result["id"], name: result["name"], size: result["size"] }, status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/backlog/tasks/:issue_key/comments/:comment_id
      # body: { content: "..." }
      def update_task_comment
        task = current_user.backlog_tasks.find_by!(issue_key: params[:issue_key])
        s = current_user.backlog_setting
        return render(json: { error: "Backlog 設定が未保存です" }, status: :bad_request) unless s&.api_key.present?
        c = BacklogClient.new(s).update_comment(task.issue_key, params[:comment_id], content: params.require(:content))
        render json: serialize_comment(c)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/backlog/tasks/:issue_key/comments/:comment_id
      def destroy_task_comment
        task = current_user.backlog_tasks.find_by!(issue_key: params[:issue_key])
        s = current_user.backlog_setting
        return render(json: { error: "Backlog 設定が未保存です" }, status: :bad_request) unless s&.api_key.present?
        BacklogClient.new(s).delete_comment(task.issue_key, params[:comment_id])
        head :no_content
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/backlog/users
      # メンション候補用の Backlog ユーザー一覧。
      # 1) Backlog API から取得（admin 不要、project members 経由）
      # 2) 取れない／取れたが少ない場合、DB の backlog_tasks.assignee_name から補完
      def users
        s = current_user.backlog_setting
        api_users = s&.api_key.present? ? BacklogClient.new(s).fetch_users : []
        result = api_users.map { |u| { id: u["id"], name: u["name"], mail_address: u["mailAddress"] } }

        # DB に同期されている assignee を補完（admin 権限が無くて API で取れなかった人を救う）
        existing_ids = result.map { |u| u[:id] }.compact
        db_assignees = BacklogTask
          .where.not(assignee_name: [ nil, "" ])
          .where.not(assignee_id: existing_ids)
          .distinct
          .pluck(:assignee_id, :assignee_name)
        db_assignees.each do |aid, aname|
          next if aname.blank?
          result << { id: aid, name: aname, mail_address: nil }
        end

        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def tasks_on_date
        target_date = Date.iso8601(params[:date].to_s)
        recent_completed_threshold = target_date - 3
        # このAPIはカレンダーの「タマ」タブ専用。リビング(source=notion)やスキルシート(source=sheet)を
        # 混ぜないよう、Backlog系(backlog / 手入力local / 旧nil)のみに絞る。リビングは /notion_tasks を使う。
        scope = viewing_user.backlog_tasks
          .where("source IS NULL OR source IN (?)", %w[backlog local])
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

      # current_user の「プライベート」ワークスペース(builtin manual)。無ければ nil。
      def private_workspace
        @private_workspace ||= current_user.progress_workspaces.find_by(name: "プライベート")
      end

      # タスクがプライベートワークスペース所属なら Google カレンダーへ push。
      # 連携未設定/権限なしでも Todo 操作自体は成功させたいので、失敗はログのみ。
      def push_to_calendar(task)
        return unless private_workspace && task.progress_workspace_id == private_workspace.id

        GoogleCalendarSync.new(current_user).push(task)
      rescue GoogleCalendarSync::ScopeError => e
        Rails.logger.warn("[backlog] calendar push skipped (scope): #{e.message}")
      rescue => e
        Rails.logger.error("[backlog] calendar push failed: #{e.class}: #{e.message}")
      end

      def remove_from_calendar(task)
        return unless private_workspace && task.progress_workspace_id == private_workspace.id

        GoogleCalendarSync.new(current_user).remove(task)
      rescue => e
        Rails.logger.error("[backlog] calendar remove failed: #{e.class}: #{e.message}")
      end

      def serialize_comment(c)
        {
          id: c["id"],
          content: c["content"],
          created_user_id: c.dig("createdUser", "id"),
          created_user_name: c.dig("createdUser", "name"),
          created: c["created"],
          updated: c["updated"]
        }
      end

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
          did_previous: t.did_previous, do_today: t.do_today,
          progress_workspace_id: t.progress_workspace_id
        }
      end
    end
  end
end
