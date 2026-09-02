module Api
  module V1
    module Admin
      # 管理対象ユーザーの一覧・作成(招待)・権限更新。
      # - admin(西野): 全ユーザー
      # - サブ管理者(テナント代表・管理割当あり。例: 西野 雄太郎 → HAUKUR運送の外注ドライバー): 管理対象+自分だけ
      # 作成すると random password で User を保存し、招待メールを当該 email 宛に送る。
      # 招待された人は Google ログインで /sign_in すれば、email 一致で from_google_oauth が
      # 既存ユーザーに provider/uid を紐付けてログイン成立する。
      class UsersController < BaseController
        before_action :ensure_supervisor

        # サブ管理者には触らせない項目(admin 専用): 管理対象の付け替え・進捗データソース権限・カレンダー人物行
        ADMIN_ONLY_KEYS = %w[managee_ids data_source_permission calendar_persons].freeze

        # GET /api/v1/admin/users
        def index
          users = User.where(id: current_user.manageable_user_ids).order(:id).includes(:managees)
          candidates = current_user.admin? ? calendar_person_candidates : []
          render json: { users: users.map { |u| serialize(u) }, calendar_person_candidates: candidates }
        end

        # PATCH /api/v1/admin/users/:id
        # params: feature_flags ({ skill_sheet: bool }), managee_ids ([Integer]), calendar_persons, work_categories, data_source_permission
        def update
          user = User.find(params[:id])
          return render(json: { error: "このユーザーを管理する権限がありません" }, status: :forbidden) unless current_user.can_manage_user?(user.id)
          unless current_user.admin?
            admin_only = ADMIN_ONLY_KEYS.select { |key| params.key?(key) }
            return render(json: { error: "#{admin_only.join(', ')} は admin のみ変更できます" }, status: :forbidden) if admin_only.any?
          end

          if params.key?(:feature_flags)
            flags = user.feature_flags.to_h
            params[:feature_flags].to_unsafe_h.each do |key, val|
              # サブ管理者は自分が使える機能しか配れない(自分に無い機能を他人に開放させない)
              next unless current_user.admin? || current_user.can_use?(key)
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

          # ユーザーごとに見せる勤怠カテゴリ。空配列/未指定は nil として保存し、
          # visible_work_categories が従来どおり全カテゴリにフォールバックする(全解除=従来運用)。
          # 不正なカテゴリ名は User のバリデーションで弾かれ、下の rescue で 422 になる。
          # サブ管理者は自分に見えるカテゴリの範囲内でしか配れない(運送代表が Tama/リビングを開放できない)。
          if params.key?(:work_categories)
            categories = Array(params.permit(work_categories: [])[:work_categories]).map(&:to_s).reject(&:empty?)
            unless current_user.admin? || (categories - current_user.visible_work_categories).empty?
              return render(json: { error: "自分に表示されないカテゴリは設定できません" }, status: :forbidden)
            end
            user.update!(work_categories: categories.presence)
          end
          update_data_source_permission(user) if params.key?(:data_source_permission)

          render json: serialize(user.reload)
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users
        # params: email, display_name, send_invite (bool, default true)
        # サブ管理者が作ったユーザーは、代表と同じ画面構成(機能フラグ・勤怠カテゴリ・締日)で始まり、
        # 作成者の管理対象+テナントメンバーになる(勤怠の閲覧対象セレクト・ユーザー一覧・カレンダー人物行に出る)。
        def create
          email = params[:email].to_s.strip.downcase
          return render(json: { error: "email が空です" }, status: :unprocessable_entity) if email.empty?
          if User.exists?(email: email)
            return render(json: { error: "そのメールアドレスのユーザーは既に登録済みです" }, status: :unprocessable_entity)
          end

          # admin かどうかは User#admin?(氏名・メール一致)で決まり、users テーブルに admin 列は無い。
          # 旧コードは admin: を渡していて常に 422(unknown attribute 'admin')になっていた。
          user = User.new(
            email: email,
            display_name: params[:display_name].to_s.strip.presence || email.split("@").first,
            password: Devise.friendly_token[0, 24]  # ランダム (本人は Google ログインで入る)
          )
          inherit_supervisor_defaults(user) unless current_user.admin?
          user.save!
          attach_to_supervisor(user) unless current_user.admin?

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

        # 「カレンダーで見える人」のチェック候補。取込データ由来の人物名(TeamSchedule.selectable_persons)に
        # 加えて、テナント(会社)に紐づくユーザーの人物行(例: 「西野 雄太郎」「運送外注」)も選べるようにする。
        # 候補に無い人物はチェックを外すこともできないため、カレンダーに出うる行はすべてここに載せる。
        def calendar_person_candidates
          tenant_user_ids = (Tenant.pluck(:owner_user_id).compact + TenantMembership.pluck(:user_id)).uniq
          tenant_persons = User.where(id: tenant_user_ids).map(&:own_calendar_person).reject(&:empty?)
          (TeamSchedule.selectable_persons + tenant_persons).uniq
        end

        def inherit_supervisor_defaults(user)
          user.feature_flags = current_user.feature_flags.to_h
          user.work_categories = current_user.work_categories
          user.closing_day = current_user.closing_day
        end

        def attach_to_supervisor(user)
          current_user.manager_assignments.find_or_create_by!(managee_id: user.id)
          current_user.owned_tenants.first&.tenant_memberships&.find_or_create_by!(user_id: user.id)
        end

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
            work_categories: user.work_categories,
            sub_admin: user.sub_admin?,
            managee_ids: user.managees.map(&:id),
            data_source_permissions: user.user_data_source_permissions.map(&:as_payload),
            calendar_persons: user.visible_calendar_persons,
            created_at: user.created_at&.iso8601
          }
        end

        # admin か、誰かを管理しているサブ管理者(テナント代表・管理割当あり)だけが入れる
        def ensure_supervisor
          return if current_user.admin? || current_user.sub_admin?
          render(json: { error: "admin または管理対象を持つユーザーのみ利用できます" }, status: :forbidden)
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
