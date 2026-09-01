module Api
  module V1
    class BaseController < ApplicationController
      before_action :authenticate_user!

      # users.linked_user_id が設定されているアカウント (例: wing西野 鷹也 が admin 西野 鷹也 に
      # 紐付いている) は、current_user を自動で linked 先 (= admin) に置き換える。
      # → 同じバックログ・進捗・請求書データを別アカウントからも編集できる。
      # super (Devise#current_user) は warden が解決した実ログインユーザー。
      def current_user
        raw = super
        return raw unless raw
        # なりすまし中は linked 解決を挟まない。挟むと wing西野(linked 先が admin 西野)に
        # なりすました瞬間に admin 西野へ戻されてしまい、本人の見え方を確認できない。
        return raw if impersonator
        @resolved_current_user ||= (raw.respond_to?(:linked_user) && raw.linked_user) || raw
      end

      # なりすまし中なら「なりすまし元の管理者」、通常ログインなら nil。
      # 出所は署名済み JWT のクレームなので、クライアント側からは偽装できない。
      def impersonator
        return @impersonator if defined?(@impersonator)
        @impersonator = User.find_by(id: jwt_claims["impersonator_id"])
      end

      # 現在のリクエストが提示している JWT のクレーム。デコードできなければ空ハッシュ。
      def jwt_claims
        @jwt_claims ||= begin
          header = request.headers["Authorization"].to_s
          header.start_with?("Bearer ") ? Warden::JWTAuth::TokenDecoder.new.call(header.delete_prefix("Bearer ")) : {}
        rescue StandardError
          {}
        end
      end

      private

      def parse_month
        if params[:month].present?
          y, m = params[:month].split("-").map(&:to_i)
          [ y, m ]
        else
          today = Date.current
          [ today.year, today.month ]
        end
      end

      def parse_application_date
        Date.iso8601(params[:application_date]) if params[:application_date].present?
      end

      # 進捗データソースの権限ゲート。before_action から使う前提で、権限が無ければ 403 を返して
      # アクション本体を実行させない。mode: :view(閲覧) / :sync(取込) / :write(外部サービスへの書き込み)
      def require_data_source!(source_type, mode)
        allowed = case mode
        when :view then current_user.can_view_data_source?(source_type)
        when :sync then current_user.can_sync_data_source?(source_type)
        when :write then current_user.can_write_data_source?(source_type)
        end
        return if allowed

        label = UserDataSourcePermission::SOURCE_LABELS[source_type]
        render json: { error: "#{label} を扱う権限がありません" }, status: :forbidden
      end

      # params[:as_user_id] で他ユーザーとして閲覧できる範囲は manageable_user_ids に一本化する:
      # 管理者=全員 / サブ管理者(テナント代表・管理割当あり。例: 雄太郎→外注ドライバー)=管理対象だけ。
      # 範囲外・未指定は常に current_user。
      def viewing_user
        return @viewing_user if defined?(@viewing_user)
        @viewing_user =
          if params[:as_user_id].present? && current_user.can_manage_user?(params[:as_user_id])
            User.find_by(id: params[:as_user_id]) || current_user
          else
            current_user
          end
      end
    end
  end
end
