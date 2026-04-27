module Api
  module V1
    class PurchaseOrderSettingsController < BaseController
      def index
        cat = params[:category].presence || "wings"
        settings = current_user.purchase_order_settings.where(category: cat).order(:position)
        render json: settings.map { |s| serialize(s) }
      end

      def show
        cat = params[:category].presence || "wings"
        pos = (params[:position] || 0).to_i
        setting = current_user.purchase_order_settings.find_by(category: cat, position: pos)
        render json: setting ? serialize(setting) : { category: cat, position: pos, exists: false }
      end

      def update
        cat = params[:category].presence || "wings"
        pos = (params[:position] || 0).to_i
        setting = current_user.purchase_order_settings.find_or_initialize_by(category: cat, position: pos)
        setting.assign_attributes(permitted_params)
        setting.save!
        render json: serialize(setting)
      end

      def destroy
        cat = params[:category].presence || "wings"
        pos = (params[:position] || 0).to_i
        setting = current_user.purchase_order_settings.find_by(category: cat, position: pos)
        setting&.destroy
        render json: { ok: true }
      end

      private

      def permitted_params
        params.require(:purchase_order_setting).permit(
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
        {
          category: setting.category,
          position: setting.position,
          exists: true,
          subject: setting.subject,
          issuer_company: setting.issuer_company,
          issuer_representative: setting.issuer_representative,
          issuer_postal: setting.issuer_postal,
          issuer_address: setting.issuer_address,
          recipient_name: setting.recipient_name,
          recipient_postal: setting.recipient_postal,
          recipient_address: setting.recipient_address,
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
          remarks: setting.remarks
        }
      end
    end
  end
end
