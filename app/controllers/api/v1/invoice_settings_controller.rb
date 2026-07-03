module Api
  module V1
    class InvoiceSettingsController < BaseController
      # as_user_id を付ければ admin は対象ユーザーの設定を取得できる(viewing_user)。
      # 非adminや as_user_id 無しは自分自身(= viewing_user は current_user)。
      def show
        cat = params[:category].presence || "wings"
        render json: serialize(viewing_user.invoice_setting_for(cat)).merge(seal_image: viewing_user.seal_image)
      end

      def update
        cat = params.dig(:invoice_setting, :category).presence || params[:category].presence || "wings"
        s = viewing_user.invoice_settings.find_or_initialize_by(category: cat)
        s.assign_attributes(InvoiceSetting.defaults_for(cat)) if s.new_record?
        s.assign_attributes(setting_params)
        s.save!
        # 印鑑画像はユーザー単位(全カテゴリ共通)。data URL を渡されたら保存、空文字なら削除。
        viewing_user.update!(seal_image: params[:seal_image].presence) if params.key?(:seal_image)
        render json: serialize(s)
      end

      def preview
        year, month = parse_month
        cat = params[:category].presence
        data = InvoicePdfRenderer.new(viewing_user, year: year, month: month, category: cat).calculation
        render json: data
      end

      private

      def setting_params
        params.require(:invoice_setting).permit(
          :client_name, :honorific, :subject, :item_label, :unit_price, :tax_rate, :payment_due_days,
          :issuer_name, :registration_no, :postal_code, :address, :tel, :email, :bank_info, :payment_due_type,
          default_items: [ :label, :qty, :unit, :price ]
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
