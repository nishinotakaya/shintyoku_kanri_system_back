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
        prs = client.pull_requests(params.require(:project), params.require(:repo))
        render json: prs.map { |pr|
          {
            number: pr["number"], summary: pr["summary"], description: pr["description"],
            base: pr["base"], branch: pr["branch"],
            created_user: pr.dig("created_user", "name"), created: pr["created"]
          }
        }
      end

      # ブランチ一覧＋ファイルツリー。sync=1 で git fetch してから返す（同期ボタン）
      def tree
        mirror = build_mirror
        mirror.sync! if params[:sync].present? || !mirror.cloned?
        branches = mirror.branches
        branch = params[:branch].presence || branches.first
        render json: { branches: branches, branch: branch, files: mirror.tree(branch) }
      rescue BacklogGitMirror::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # ファイル内容
      def file
        mirror = build_mirror
        content = mirror.file(params.require(:branch), params.require(:path))
        render json: { path: params[:path], content: content }
      rescue BacklogGitMirror::Error => e
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
      end

      private

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
    end
  end
end
