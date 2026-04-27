module Api
  module V1
    class InvoiceSettingsController < BaseController
      def show
        cat = params[:category].presence || "wings"
        render json: serialize(current_user.invoice_setting_for(cat))
      end

      def update
        cat = params.dig(:invoice_setting, :category).presence || params[:category].presence || "wings"
        s = current_user.invoice_settings.find_or_initialize_by(category: cat)
        s.assign_attributes(InvoiceSetting.defaults_for(cat)) if s.new_record?
        s.assign_attributes(setting_params)
        s.save!
        render json: serialize(s)
      end

      def preview
        year, month = parse_month
        cat = params[:category].presence
        data = InvoicePdfRenderer.new(current_user, year: year, month: month, category: cat).calculation
        render json: data
      end

      private

      def setting_params
        params.require(:invoice_setting).permit(
          :client_name, :honorific, :subject, :item_label, :unit_price, :tax_rate, :payment_due_days,
          :issuer_name, :registration_no, :postal_code, :address, :tel, :email, :bank_info, :payment_due_type,
          default_items: [:label, :qty, :unit, :price]
        )
      end

      def serialize(s)
        {
          category: s.category,
          client_name: s.client_name, honorific: s.honorific, subject: s.subject, item_label: s.item_label,
          unit_price: s.unit_price, tax_rate: s.tax_rate, payment_due_days: s.payment_due_days,
          issuer_name: s.issuer_name, registration_no: s.registration_no,
          postal_code: s.postal_code, address: s.address, tel: s.tel, email: s.email,
          bank_info: s.bank_info, payment_due_type: s.payment_due_type, default_items: s.default_items
        }
      end
    end
  end
end
