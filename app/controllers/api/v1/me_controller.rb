module Api
  module V1
    class MeController < BaseController
      def show
        render json: payload
      end

      # 勤怠/カレンダーの「他ユーザーとして閲覧」セレクト用。admin は全員、サブ管理者(テナント代表・管理割当あり)は
      # 管理対象+自分。それ以外は空(セレクトを出さない)。
      def pickable_users
        return render(json: []) unless current_user.admin? || current_user.sub_admin?
        users = User.where(id: current_user.manageable_user_ids).order(:id)
        render json: users.map { |u| { id: u.id, display_name: u.display_name, email: u.email, admin: u.admin? } }
      end

      def update
        # 個人番号(my_number)/生年月日(birth_date)は、確定申告PDF(admin=西野専用)にしか使わない。
        # 他ユーザーの個人番号をサーバに保管しないため、admin 以外からの登録は丸ごと拒否する
        # (キーだけ無視して残りを更新すると「送ったのに保存されない」事故になるため 403 で止める)。
        if my_number_fields_requested? && !current_user.admin?
          return render(json: { error: "個人番号の登録は管理者(本人)のみ利用できます" }, status: :forbidden)
        end

        current_user.update!(me_params)
        render json: payload
      end

      # POST /api/v1/me/my_number_card/read (multipart: files[]=マイナンバーカード表裏。file 単体も可)
      # 保存はしない(保存は update の my_number / birth_date params で行う)。
      # 確定申告PDF(admin専用)にしか使わないため、admin 以外は利用不可(他ユーザーの個人番号を扱わない)。
      def read_my_number_card
        unless current_user.admin?
          return render(json: { error: "個人番号の登録は管理者(本人)のみ利用できます" }, status: :forbidden)
        end

        files = Array(params[:files]).presence || Array(params[:file])
        files = files.select { |file| file.respond_to?(:read) }
        return render(json: { error: "マイナンバーカードの画像を添付してください" }, status: :unprocessable_entity) if files.blank?

        images = files.map { |file| { bytes: file.read, content_type: file.respond_to?(:content_type) ? file.content_type : "image/jpeg" } }
        result = MyNumberCardReader.call(images)
        return render(json: { error: result[:error] }, status: :unprocessable_entity) if result[:error]

        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def import_schedule
        year = (params[:year].presence || Date.current.year).to_i
        month = (params[:month].presence || Date.current.month).to_i
        result = AttendanceScheduleImporter.new(user: current_user, year: year, month: month).call_and_apply
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # params[:user] に my_number / birth_date のキー自体が含まれているか(値の有無は問わない)。
      # 空文字での「消去」リクエストも admin 以外からは弾く。
      def my_number_fields_requested?
        raw = params[:user]
        return false unless raw.respond_to?(:key?)
        raw.key?(:my_number) || raw.key?(:birth_date)
      end

      def me_params
        permitted = params.require(:user).permit(:display_name, :company_name, :openai_api_key, :heygen_api_key,
          :trello_api_key, :trello_api_token, :trello_board_id, :video_script_context, :closing_day,
          :default_transit_from, :default_transit_to, :default_transit_fee, :default_transit_line,
          :postal_code, :address, :tax_office, :name_kana, :attendance_schedule_url, :progress_sheet_url, :local_save_dir, :dev_language, :gender,
          :my_number, :birth_date,
          custom_off_days: [], commute_days: [],
          transit_routes: [ :from, :to, :fee, :line ])
        # date型に空文字を渡すと invalid date エラーになるため、明示的に nil にする(my_number は normalizes 側で処理)
        permitted[:birth_date] = nil if permitted.key?(:birth_date) && permitted[:birth_date].blank?
        permitted
      end

      def payload
        {
          id: current_user.id,
          email: current_user.email,
          display_name: current_user.display_name,
          company_name: current_user.company_name,
          closing_day: current_user.closing_day,
          openai_api_key_set: current_user.openai_api_key.present?,
          heygen_api_key_set: current_user.heygen_api_key.present?,
          heygen_available: HeygenClient.api_key_for(current_user).present?,
          trello_api_key_set: current_user.trello_api_key.present?,
          trello_api_token_set: current_user.trello_api_token.present?,
          trello_board_id: current_user.trello_board_id,
          video_script_context: current_user.video_script_context,
          custom_off_days: current_user.custom_off_days || [],
          default_transit_from: current_user.default_transit_from,
          default_transit_to: current_user.default_transit_to,
          default_transit_fee: current_user.default_transit_fee,
          default_transit_line: current_user.default_transit_line,
          transit_routes: current_user.transit_routes || [],
          commute_days: current_user.commute_days || [],
          can_issue_orders: current_user.can_issue_orders,
          postal_code: current_user.postal_code,
          address: current_user.address,
          tax_office: current_user.tax_office,
          name_kana: current_user.try(:name_kana), # migrate前でも落ちないようtry
          # 個人番号そのものは返さない。登録有無と末尾4桁だけ。admin以外は他ユーザーの個人番号を
          # サーバに保管しない方針のため、そもそも常に未登録(nil/false)として返す
          my_number_registered: current_user.admin? && current_user.my_number.present?,
          my_number_last4: current_user.admin? ? current_user.my_number_last4 : nil,
          birth_date: current_user.admin? ? current_user.birth_date&.iso8601 : nil,

          attendance_schedule_url: current_user.attendance_schedule_url,
          progress_sheet_url: current_user.progress_sheet_url,
          local_save_dir: current_user.local_save_dir,
          dev_language: current_user.dev_language,
          gender: current_user.gender,
          admin: current_user.admin?,
          feature_flags: current_user.feature_flags.to_h,
          work_categories: current_user.work_categories,
          tax_status: current_user.tax_status,
          can_use_skill_sheet: current_user.can_use?(:skill_sheet),
          can_use_interview_mindmap: current_user.can_use?(:interview_mindmap),
          can_use_youtube_mindmap: current_user.can_use?(:youtube_mindmap),
          can_use_mote_mindmap: current_user.can_use?(:mote_mindmap),
          can_use_mote_qa_mindmap: current_user.can_use?(:mote_qa_mindmap),
          can_use_love_youtube_mindmap: current_user.can_use?(:love_youtube_mindmap),
          can_use_talk_cards_mindmap: current_user.can_use?(:talk_cards_mindmap),
          # 進捗データソースごとの可否。フロントはこれでリビング/テックリーダーズの表示を出し分ける
          viewable_data_sources: current_user.viewable_data_source_types,
          calendar_persons: current_user.visible_calendar_persons,
          # 自分の人物行と、そのうち操作できる行。編集可否の判定はサーバに一本化する
          own_calendar_person: current_user.own_calendar_person,
          editable_calendar_persons: current_user.editable_calendar_persons,
          # カレンダー見出しに出す会社(テナント)名。HAUKUR運送 / プロアカ
          tenant_name: current_user.tenant_name,
          writable_data_sources: UserDataSourcePermission::SOURCE_TYPES.select { |source| current_user.can_write_data_source?(source) },
          sub_admin: current_user.sub_admin?,
          # なりすまし中なら戻り先の管理者。フロントはこれでバナーを出すので localStorage に依存しない
          impersonator: impersonator && { id: impersonator.id, display_name: impersonator.display_name }
        }
      end
    end
  end
end
