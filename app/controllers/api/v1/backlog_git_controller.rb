module Api
  module V1
    # GitHub風の Backlog Git レビュー画面用 API。
    # リポジトリ/PR は Backlog REST API、ファイルツリー/内容は BacklogGitMirror(shallow clone) から返す。
    class BacklogGitController < BaseController
      before_action :require_setting!

      # プロジェクトごとの git リポジトリ一覧（git 無効プロジェクトはスキップ）
      def repositories
        result = client.projects.filter_map do |proj|
          repos = begin
            client.git_repositories(proj["projectKey"])
          rescue StandardError
            next # git 機能が無効のプロジェクト
          end
          next if repos.blank?
          {
            project_key: proj["projectKey"],
            project_name: proj["name"],
            repositories: repos.map { |r| { name: r["name"], description: r["description"] } }
          }
        end
        render json: result
      end

      # PR 一覧（オープン）
      def pull_requests
        project = params.require(:project)
        repo = params.require(:repo)
        prs = client.pull_requests(project, repo)
        render json: prs.map { |pr|
          {
            number: pr["number"], summary: pr["summary"], description: pr["description"],
            base: pr["base"], branch: pr["branch"],
            created_user: pr.dig("created_user", "name"), created: pr["created"],
            # 一覧のコメント数バッジ。件数取得失敗は 0 扱いにして一覧自体は返す
            comment_count: (client.pull_request_comment_count(project, repo, pr["number"]) rescue 0),
            url: pull_request_url(project, repo, pr["number"])
          }
        }
      end

      # ブランチ一覧＋ファイルツリー。sync=1 で git fetch してから返す（同期ボタン）
      def tree
        mirror = build_mirror
        mirror.sync! if params[:sync].present? || !mirror.cloned?
        branches = mirror.branches
        # リポジトリ切替などで存在しないブランチ名が来ても落とさずデフォルトにフォールバック
        branch = branches.include?(params[:branch]) ? params[:branch] : branches.first
        render json: { branches: branches, branch: branch, files: mirror.tree(branch) }
      rescue BacklogGitMirror::Error, RuntimeError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PR 詳細: 説明・既存コメント・変更ファイル(diff) をまとめて返す
      def pr_detail
        project = params.require(:project)
        repo = params.require(:repo)
        number = params.require(:number)
        pr = client.pull_request(project, repo, number)
        comments = client.pull_request_comments(project, repo, number)
        mirror = build_mirror
        mirror.sync! # PR ブランチが clone 後にできた場合に備えて毎回 fetch
        diff_error = nil
        files = begin
          mirror.parsed_diff(pr["base"], pr["branch"])
        rescue BacklogGitMirror::Error => e
          diff_error = e.message
          []
        end
        render json: {
          number: pr["number"], summary: pr["summary"], description: pr["description"],
          base: pr["base"], branch: pr["branch"], status: pr.dig("status", "name"),
          created_user: pr.dig("created_user", "name"), created: pr["created"],
          comments: comments.filter_map { |c|
            next if c["content"].blank?
            { id: c["id"], user: c.dig("createdUser", "name"), content: c["content"], created: c["created"] }
          },
          files: files, diff_error: diff_error,
          url: pull_request_url(project, repo, pr["number"])
        }
      rescue BacklogGitMirror::Error, RuntimeError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # ── システム内のみの PR メモ（Backlog には送らない） ──
      def notes
        notes = GitPrNote.for_pr(params.require(:project), params.require(:repo), params.require(:number))
        render json: notes.map { |n| serialize_note(n) }
      end

      def create_note
        note = GitPrNote.create!(
          user: current_user,
          project_key: params.require(:project), repo_name: params.require(:repo),
          pr_number: params.require(:number), content: params.require(:content)
        )
        render json: serialize_note(note), status: :created
      end

      def destroy_note
        note = GitPrNote.find(params[:id])
        return render(json: { error: "自分のメモだけ削除できます" }, status: :forbidden) unless note.user_id == current_user.id
        note.destroy!
        render json: { ok: true }
      end

      # PR への単発コメント投稿
      def post_comment
        result = client.add_pull_request_comment(
          params.require(:project), params.require(:repo), params.require(:number), params.require(:content)
        )
        render json: { comment_id: result["id"] }
      rescue RuntimeError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # ファイル内容
      def file
        mirror = build_mirror
        content = mirror.file(params.require(:branch), params.require(:path))
        render json: { path: params[:path], content: content }
      rescue BacklogGitMirror::Error, RuntimeError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 一斉レビュー投稿: 下書きコメント群を1つの markdown に結合して PR コメントへ POST
      # params: project, repo, number, comments: [{ path, line, code, body }]
      def post_review
        comments = params.require(:comments)
        content = +"#### 📝 コードレビュー（#{Time.zone.now.strftime('%Y-%m-%d %H:%M')} / #{current_user.display_name}）\n\n"
        comments.each do |c|
          content << "---\n**`#{c[:path]}:#{c[:line]}`**\n"
          content << "```\n#{c[:code]}\n```\n" if c[:code].present?
          content << "#{c[:body]}\n\n"
        end
        result = client.add_pull_request_comment(
          params.require(:project), params.require(:repo), params.require(:number), content
        )
        render json: { posted: comments.size, comment_id: result["id"] }
      rescue RuntimeError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def serialize_note(note)
        { id: note.id, user: note.user.display_name, mine: note.user_id == current_user.id,
          content: note.content, created: note.created_at.iso8601 }
      end

      def require_setting!
        s = current_user.backlog_setting
        return if s&.api_key.present?
        render json: { error: "Backlog 設定（APIキー）が未保存です。設定画面から登録してください。" }, status: :bad_request
      end

      def client
        @client ||= BacklogClient.new(current_user.backlog_setting)
      end

      def build_mirror
        BacklogGitMirror.new(client, params.require(:project), params.require(:repo))
      end

      # Backlog 上の PR ページへの直リンク
      def pull_request_url(project_key, repo_name, pr_number)
        backlog_url = current_user.backlog_setting.backlog_url.to_s.chomp("/")
        return nil if backlog_url.blank?
        "#{backlog_url}/git/#{project_key}/#{repo_name}/pullRequests/#{pr_number}"
      end
    end
  end
end
