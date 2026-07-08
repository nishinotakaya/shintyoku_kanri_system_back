module Api
  module V1
    # GitHub のリポジトリ/PR 閲覧・コメント投稿用 API。
    class GithubReposController < BaseController
      before_action :require_github_setting!

      # リポジトリ一覧。setting.default_repos に登録された "owner/repo" があれば先頭に並べる。
      def repositories
        repos = client.repositories
        default_full_names = default_repo_names
        return render(json: repos) if default_full_names.blank?

        prioritized, others = repos.partition { |repo| default_full_names.include?(repo[:full_name]) }
        prioritized.sort_by! { |repo| default_full_names.index(repo[:full_name]) }
        render json: prioritized + others
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def pull_requests
        prs = client.pull_requests(params.require(:full_name), state: params[:state].presence || "all")
        render json: prs
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def pr_detail
        detail = client.pull_request_detail(params.require(:full_name), params.require(:number))
        render json: detail
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def create_comment
        body = params[:body].to_s
        return render(json: { error: "コメント本文を入力してください" }, status: :unprocessable_entity) if body.blank?

        comment = client.create_comment(params.require(:full_name), params.require(:number), body)
        render json: comment, status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 変更ファイル単位のレビューコメント投稿
      def create_review_comment
        body = params[:body].to_s
        return render(json: { error: "コメント本文を入力してください" }, status: :unprocessable_entity) if body.blank?

        comment = client.create_review_comment(
          params.require(:full_name), params.require(:number),
          params.require(:commit_id), params.require(:path), body
        )
        render json: comment, status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 自分宛ての通知(メンション・レビュー依頼・コメント等)
      def notifications
        render json: client.notifications
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def default_repo_names
        current_user.github_setting.default_repos.to_s.split("\n").map(&:strip).reject(&:blank?)
      end

      def require_github_setting!
        s = current_user.github_setting
        return if s&.personal_access_token.present?
        render json: { error: "GitHub設定（アクセストークン）が未保存です。設定画面から登録してください。" }, status: :bad_request
      end

      def client
        @client ||= GithubClient.new(current_user.github_setting)
      end
    end
  end
end
