module Api
  module V1
    module Auth
      class RegistrationsController < Devise::RegistrationsController
        respond_to :json

        private

        def respond_with(resource, _opts = {})
          if resource.persisted?
            render json: {
              user: { id: resource.id, email: resource.email, display_name: resource.display_name, company_name: resource.company_name },
              token: request.env["warden-jwt_auth.token"] || response.headers["Authorization"]&.sub("Bearer ", "")
            }, status: :created
          else
            render json: { error: resource.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
