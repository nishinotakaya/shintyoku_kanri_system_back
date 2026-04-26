module Api
  module V1
    module Auth
      class SessionsController < Devise::SessionsController
        respond_to :json

        private

        def respond_with(resource, _opts = {})
          render json: {
            user: user_payload(resource),
            token: request.env["warden-jwt_auth.token"] || response.headers["Authorization"]&.sub("Bearer ", "")
          }, status: :ok
        end

        def respond_to_on_destroy
          if current_user
            render json: { message: "signed out" }, status: :ok
          else
            render json: { error: "not signed in" }, status: :unauthorized
          end
        end

        def user_payload(user)
          { id: user.id, email: user.email, display_name: user.display_name, company_name: user.company_name }
        end
      end
    end
  end
end
