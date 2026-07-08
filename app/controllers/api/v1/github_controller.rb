module Api
  module V1
    class GithubController < BaseController
      def show_setting
        s = current_user.github_setting || current_user.build_github_setting
        render json: serialize_setting(s)
      end

      def update_setting
        s = current_user.github_setting || current_user.build_github_setting
        attrs = setting_params
        # personal_access_token は空文字なら更新しない（隠している既存値を消さないため）
        attrs = attrs.except(:personal_access_token) if attrs[:personal_access_token].blank?
        s.assign_attributes(attrs)
        s.save!
        render json: serialize_setting(s)
      end

      def test_connection
        s = current_user.github_setting
        return render(json: { success: false, error: "設定が未保存です" }) unless s&.personal_access_token.present?

        result = GithubClient.new(s).me
        render json: { success: true, login: result[:login], name: result[:name] }
      rescue => e
        render json: { success: false, error: e.message }
      end

      private

      def setting_params
        params.require(:github_setting).permit(:personal_access_token, :default_repos, :display_name)
      end

      def serialize_setting(s)
        {
          has_token: s.personal_access_token.present?,
          default_repos: s.default_repos,
          display_name: s.display_name
        }
      end
    end
  end
end
