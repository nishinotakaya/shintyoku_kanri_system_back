module Api
  module V1
    class PurchaseOrderSettingsController < BaseController
      include FreeeReportable
      def index
        cat = params[:category].presence
        # admin (西野) は自分が発行したテンプレを全部、非 admin (川村など) は recipient_user_id=自分のテンプレを取得
        scope = current_user.admin? ? current_user.purchase_order_settings : PurchaseOrderSetting.where(recipient_user_id: current_user.id)
        scope = scope.where(category: cat) if cat.present?
        settings = scope.order(:category, :position)
        render json: settings.map { |s| serialize(s) }
      end

      def show
        cat = params[:category].presence || "wings"
        pos = (params[:position] || 0).to_i
        # admin: 自分のテンプレ。非admin: 自分宛のテンプレ
        setting =
          if current_user.admin?
            current_user.purchase_order_settings.find_by(category: cat, position: pos)
          else
            PurchaseOrderSetting.where(recipient_user_id: current_user.id).find_by(category: cat, position: pos)
          end
        render json: setting ? serialize(setting) : { category: cat, position: pos, exists: false }
      end

      def update
        return render(json: { error: "編集権限がありません" }, status: :forbidden) unless current_user.admin?
        cat = params[:category].presence || "wings"
        pos = (params[:position] || 0).to_i
        setting = current_user.purchase_order_settings.find_or_initialize_by(category: cat, position: pos)
        setting.assign_attributes(permitted_params)
        # recipient_user_id は recipient_name と整合させる: 受注者ユーザーが指定されていれば設定し、recipient_name も上書き
        if params[:recipient_user_id].present?
          recipient_user = User.find_by(id: params[:recipient_user_id])
          if recipient_user
            setting.recipient_user = recipient_user
            setting.recipient_name = recipient_user.display_name if setting.recipient_name.blank?
          end
        elsif setting.recipient_user_id.nil? && setting.recipient_name.present?
          # recipient_name から自動で recipient_user を推定
          normalized = setting.recipient_name.gsub(/\s+/, "")
          User.where.not(display_name: [ nil, "" ]).find_each do |u|
            if normalized.include?(u.display_name.gsub(/\s+/, ""))
              setting.recipient_user = u
              break
            end
          end
        end
        setting.save!
        render json: serialize(setting)
      end

      def destroy
        return render(json: { error: "削除権限がありません" }, status: :forbidden) unless current_user.admin?
        cat = params[:category].presence || "wings"
        pos = (params[:position] || 0).to_i
        setting = current_user.purchase_order_settings.find_by(category: cat, position: pos)
        setting&.destroy
        render json: { ok: true }
      end

      # PATCH /api/v1/purchase_order_settings/reorder?category=wings
      # body: { positions: [2, 0, 1] }  ← 現在の position 配列を、新しい並び順 (index=新position) で送る
      # (user_id, category, position) に unique 制約があるので、いったん負値に逃がしてから本割り当て
      def reorder
        return render(json: { error: "編集権限がありません" }, status: :forbidden) unless current_user.admin?
        cat = params[:category].presence || "wings"
        new_order = Array(params[:positions]).map(&:to_i)
        scope = current_user.purchase_order_settings.where(category: cat)
        settings_by_pos = scope.where(position: new_order).index_by(&:position)
        ActiveRecord::Base.transaction do
          settings_by_pos.each_value { |s| s.update_column(:position, -(s.position + 1) - 1000) }
          new_order.each_with_index do |old_pos, new_pos|
            settings_by_pos[old_pos]&.update_column(:position, new_pos)
          end
        end
        render json: scope.order(:position).map { |s| serialize(s) }
      end

      # POST /api/v1/purchase_order_settings/:id/report_to_freee
      # 西野が発注者の PO (発行 PO) を freee に経費 (type=expense) として計上する。
      def report_to_freee
        rec = current_user.purchase_order_settings.find(params[:id])

        items = Array(rec.items)
        subtotal = items.sum { |it| (it["amount"] || it[:amount]).to_i }
        total = (subtotal * 1.1).round
        return render(json: { error: "金額が 0 円のため計上不可" }, status: :unprocessable_entity) if total.zero?

        partner_id = ENV["FREEE_PARTNER_#{rec.recipient_name.to_s.upcase}"].presence&.to_i ||
                     ENV["FREEE_PARTNER_KAWAMURA"].presence&.to_i
        unless partner_id
          return render(json: { error: "取引先 partner_id 未設定。FREEE_PARTNER_KAWAMURA 等を Fly secret で設定してください。" }, status: :bad_request)
        end

        due = rec.period_end || Date.new(Date.current.year, Date.current.month, -1)

        report_record_to_freee!(
          record: rec,
          invoice_payload: {
            total_amount: total,
            due_date: due.to_s,
            subject: rec.subject || "#{rec.category} 業務委託",
            partner_id: partner_id
          },
          transaction_type: "expense",
          success_message: "freee 経費計上完了"
        )
      end

      private

      def permitted_params
        params.require(:purchase_order_setting).permit(
          :order_no,
          :subject,
          :issuer_company, :issuer_representative, :issuer_postal, :issuer_address,
          :recipient_name, :recipient_postal, :recipient_address,
          :period_start, :period_end,
          :closing_day, :hours_per_cycle, :rate_per_hour, :base_monthly, :unit,
          :price_mode, :range_min, :range_max,
          :delivery_location, :payment_method, :remarks,
          items: [ :description, :qty, :unit, :unit_price, :amount ]
        )
      end

      def serialize(setting)
        items = Array(setting.items)
        subtotal = items.sum { |it| (it["amount"] || it[:amount]).to_i }
        total_amount = (subtotal * 1.1).round
        {
          id: setting.id,
          category: setting.category,
          position: setting.position,
          exists: true,
          order_no: setting.order_no,
          subject: setting.subject,
          total_amount: total_amount,
          issuer_company: setting.issuer_company,
          issuer_representative: setting.issuer_representative,
          issuer_postal: setting.issuer_postal,
          issuer_address: setting.issuer_address,
          recipient_name: setting.recipient_name,
          recipient_postal: setting.recipient_postal,
          recipient_address: setting.recipient_address,
          recipient_user_id: setting.recipient_user_id,
          recipient_user_display_name: setting.recipient_user&.display_name,
          issuer_user_id: setting.user_id,
          issuer_user_display_name: setting.user&.display_name,
          period_start: setting.period_start&.iso8601,
          period_end: setting.period_end&.iso8601,
          closing_day: setting.closing_day,
          hours_per_cycle: setting.hours_per_cycle,
          rate_per_hour: setting.rate_per_hour,
          base_monthly: setting.base_monthly,
          unit: setting.unit,
          price_mode: setting.price_mode,
          range_min: setting.range_min,
          range_max: setting.range_max,
          delivery_location: setting.delivery_location,
          payment_method: setting.payment_method,
          items: setting.items,
          remarks: setting.remarks,
          freee_deal_id: setting.freee_deal_id,
          freee_reported_at: setting.freee_reported_at&.iso8601
        }
      end
    end
  end
end
