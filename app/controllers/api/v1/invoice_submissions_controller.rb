module Api
  module V1
    class InvoiceSubmissionsController < BaseController
      # admin: 全ユーザーの申請を表示。それ以外: 自分の申請のみ。
      # 既定では status=pending を返す。?status=all で全件、?status=approved で承認済のみ。
      def index
        scope = current_user.admin? ? InvoiceSubmission.all : InvoiceSubmission.where(user_id: current_user.id)
        case params[:status].to_s
        when "all"
          # no filter
        when "approved"
          scope = scope.approved
        else
          scope = scope.pending
        end
        records = scope.order(submitted_at: :desc).includes(:user, :reviewer)
        render json: records.map { |r| serialize(r) }
      end

      def create
        record = InvoiceSubmission.new(
          user: current_user,
          year: params[:year].to_i,
          month: params[:month].to_i,
          category: params[:category].to_s.presence || "wings",
          note: params[:note].to_s.presence,
          status: "pending"
        )
        record.save!
        render json: serialize(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 承認/却下は admin のみ
      def update
        return render(json: { error: "承認権限がありません" }, status: :forbidden) unless current_user.admin?
        record = InvoiceSubmission.find(params[:id])
        new_status = params[:status].to_s
        return render(json: { error: "不正なステータス" }, status: :unprocessable_entity) unless InvoiceSubmission::STATUSES.include?(new_status)
        record.update!(
          status: new_status,
          reviewer_id: current_user.id,
          reviewed_at: Time.current,
          note: params[:note].present? ? params[:note].to_s : record.note
        )
        render json: serialize(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def serialize(record)
        {
          id: record.id,
          user_id: record.user_id,
          user_display_name: record.user&.display_name,
          year: record.year,
          month: record.month,
          year_month: record.year_month,
          category: record.category,
          status: record.status,
          submitted_at: record.submitted_at&.iso8601,
          reviewed_at: record.reviewed_at&.iso8601,
          reviewer_id: record.reviewer_id,
          reviewer_display_name: record.reviewer&.display_name,
          note: record.note
        }
      end
    end
  end
end
