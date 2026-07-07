module Api
  module V1
    class MeController < BaseController
      def show
        render json: payload
      end

      # 管理者のみ: カレンダーで「他ユーザーとして閲覧」する選択肢を返す
      def pickable_users
        return render(json: []) unless current_user.admin?
        render json: User.order(:id).map { |u| { id: u.id, display_name: u.display_name, email: u.email, admin: u.admin? } }
      end

      def update
        current_user.update!(me_params)
        render json: payload
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

      def me_params
        params.require(:user).permit(:display_name, :company_name, :openai_api_key, :heygen_api_key, :video_script_context, :closing_day,
          :default_transit_from, :default_transit_to, :default_transit_fee, :default_transit_line,
          :postal_code, :address, :tax_office, :attendance_schedule_url, :progress_sheet_url, :local_save_dir, :dev_language,
          custom_off_days: [], commute_days: [],
          transit_routes: [ :from, :to, :fee, :line ])
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
          attendance_schedule_url: current_user.attendance_schedule_url,
          progress_sheet_url: current_user.progress_sheet_url,
          local_save_dir: current_user.local_save_dir,
          dev_language: current_user.dev_language,
          admin: current_user.admin?,
          feature_flags: current_user.feature_flags.to_h,
          tax_status: current_user.tax_status,
          can_use_skill_sheet: current_user.can_use?(:skill_sheet),
          can_use_interview_mindmap: current_user.can_use?(:interview_mindmap),
          can_use_youtube_mindmap: current_user.can_use?(:youtube_mindmap),
          can_use_mote_mindmap: current_user.can_use?(:mote_mindmap),
          sub_admin: current_user.sub_admin?
        }
      end
    end
  end
end
