module Api
  module V1
    module Admin
      # admin が他のユーザーを作成・招待するためのコントローラ。
      # 作成すると random password で User を保存し、招待メールを当該 email 宛に送る。
      # 招待された人は Google ログインで /sign_in すれば、email 一致で from_google_oauth が
      # 既存ユーザーに provider/uid を紐付けてログイン成立する。
      class UsersController < BaseController
        before_action :ensure_admin

        # GET /api/v1/admin/users
        def index
          users = User.order(:id).includes(:managees)
          render json: { users: users.map { |u| serialize(u) }, calendar_person_candidates: TeamSchedule.selectable_persons }
        end

        # PATCH /api/v1/admin/users/:id
        # params: feature_flags ({ skill_sheet: bool }), managee_ids ([Integer])
        def update
          user = User.find(params[:id])

          if params.key?(:feature_flags)
            flags = user.feature_flags.to_h
            params[:feature_flags].to_unsafe_h.each do |key, val|
              flags[key.to_s] = ActiveModel::Type::Boolean.new.cast(val)
            end
            user.feature_flags = flags
          end

          user.save!

          if params.key?(:managee_ids)
            ids = Array(params[:managee_ids]).map(&:to_i).reject { |i| i == user.id }
            user.manager_assignments.where.not(managee_id: ids).destroy_all
            ids.each do |mid|
              user.manager_assignments.find_or_create_by!(managee_id: mid)
            end
          end

          # 配列は permit を通さないと取り出せない(params[:calendar_persons] だけでは nil になる)
          if params.key?(:calendar_persons)
            persons = params.permit(calendar_persons: [])[:calendar_persons]
            user.update!(calendar_persons: Array(persons).map(&:to_s).reject(&:empty?))
          end
          update_data_source_permission(user) if params.key?(:data_source_permission)

          render json: serialize(user.reload)
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users
        # params: email, display_name, admin (bool), send_invite (bool, default true)
        def create
          email = params[:email].to_s.strip.downcase
          return render(json: { error: "email が空です" }, status: :unprocessable_entity) if email.empty?
          if User.exists?(email: email)
            return render(json: { error: "そのメールアドレスのユーザーは既に登録済みです" }, status: :unprocessable_entity)
          end

          user = User.new(
            email: email,
            display_name: params[:display_name].to_s.strip.presence || email.split("@").first,
            password: Devise.friendly_token[0, 24],  # ランダム (本人は Google ログインで入る)
            admin: ActiveModel::Type::Boolean.new.cast(params[:admin])
          )
          user.save!

          send_invite = params[:send_invite].nil? || ActiveModel::Type::Boolean.new.cast(params[:send_invite])
          invite_sent = false
          invite_error = nil
          if send_invite
            begin
              send_invitation_email(user)
              invite_sent = true
            rescue => e
              invite_error = e.message
              Rails.logger.error("[admin/users#create] invite mail failed: #{e.class}: #{e.message}")
            end
          end

          render json: {
            id: user.id, email: user.email, display_name: user.display_name, admin: user.admin?,
            invite_sent: invite_sent, invite_error: invite_error
          }, status: :created
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        # params: data_source_permission { source_type, can_view, can_sync, can_write, credential_owner_id }
        # 1ソースずつ更新する。can_view が false になったらそのソースは丸ごと不可に倒す
        # (閲覧できないのに同期・書き込みだけ通る状態を作らない)。
        def update_data_source_permission(user)
          permission_params = params[:data_source_permission]
          source_type = permission_params[:source_type].to_s
          return unless UserDataSourcePermission::SOURCE_TYPES.include?(source_type)

          permission = user.user_data_source_permissions.find_or_initialize_by(source_type: source_type)
          permission.can_view = boolean_param(permission_params[:can_view]) if permission_params.key?(:can_view)
          permission.can_sync = boolean_param(permission_params[:can_sync]) if permission_params.key?(:can_sync)
          permission.can_write = boolean_param(permission_params[:can_write]) if permission_params.key?(:can_write)
          if permission_params.key?(:credential_owner_id)
            permission.credential_owner_id = permission_params[:credential_owner_id].presence&.to_i
          end
          unless permission.can_view
            permission.can_sync = false
            permission.can_write = false
          end
          permission.save!
        end

        def boolean_param(value)
          ActiveModel::Type::Boolean.new.cast(value) || false
        end

        def serialize(user)
          {
            id: user.id, email: user.email, display_name: user.display_name,
            admin: user.admin?, has_google: user.provider.present?,
            feature_flags: user.feature_flags.to_h,
            sub_admin: user.sub_admin?,
            managee_ids: user.managees.map(&:id),
            data_source_permissions: user.user_data_source_permissions.map(&:as_payload),
            calendar_persons: user.visible_calendar_persons,
            created_at: user.created_at&.iso8601
          }
        end

        def ensure_admin
          render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        end

        def send_invitation_email(invitee)
          sign_in_url = ENV["FRONTEND_URL"].presence || "https://react-frontend-beige.vercel.app"
          subject = "【勤怠アプリ】#{current_user.display_name}さんから招待が届きました"
          body = <<~BODY
            #{invitee.display_name} 様

            #{current_user.display_name}さんが勤怠アプリにあなたを招待しました。

            下記URLにアクセスし、Googleアカウント（このメールアドレス: #{invitee.email}）でログインしてください。
            #{sign_in_url}/sign_in

            ※ Googleログインのメールアドレスが上記と一致すれば、自動で本アプリのアカウントに紐づきます。
            ※ ログイン後、メニュー右上の ⚙ 設定 → アカウント から表示名や請求書情報を編集できます。

            ご不明点があれば #{current_user.email} までご連絡ください。

            ---
            勤怠アプリ
          BODY

          GmailSender.new(user: current_user).send_mail(
            to: invitee.email,
            subject: subject,
            body: body,
            from_name: current_user.display_name
          )
        end
      end
    end
  end
end
