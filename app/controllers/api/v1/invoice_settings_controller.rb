module Api
  module V1
    class InvoiceSettingsController < BaseController
      # as_user_id を付ければ admin は対象ユーザーの設定を取得できる(viewing_user)。
      # 非adminや as_user_id 無しは自分自身(= viewing_user は current_user)。
      def show
        cat = resolve_category(params[:category]) or return
        render json: serialize(viewing_user.invoice_setting_for(cat)).merge(seal_image: viewing_user.seal_image)
      end

      def update
        cat = resolve_category(params.dig(:invoice_setting, :category).presence || params[:category]) or return
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

      # 読み書きするカテゴリ。未指定なら、そのユーザーが見える先頭のカテゴリ(運送専用ユーザーなら transport)。
      # 以前は無条件に wings を既定にしていたため、運送専用ユーザーの画面に Tama の設定(ラボップ宛・
      # シェアラウンジ利用料)が読み込まれ、保存も wings 側に落ちて「設定を変えても計算が変わらない」状態になっていた。
      # work_categories を設定しているユーザーは、見えないカテゴリの設定を作らせない(422)。
      def resolve_category(raw)
        visible = viewing_user.visible_work_categories
        category = raw.presence || visible.first
        return category if viewing_user.work_categories.blank? || visible.include?(category)

        render json: { error: "#{InvoiceSetting.category_label(category)} はこのユーザーには表示されないカテゴリです" },
               status: :unprocessable_entity
        nil
      end

      def setting_params
        params.require(:invoice_setting).permit(
          :client_name, :honorific, :subject, :item_label, :unit_price, :merged_unit_price, :tax_rate, :tax_included, :payment_due_days,
          :pay_type, :daily_rate, :standard_hours, :overtime_unit_price,
          :issuer_name, :registration_no, :postal_code, :address, :tel, :email, :bank_info, :payment_due_type,
          default_items: [ :label, :qty, :unit, :price ]
        )
      end

      def serialize(s)
        {
          category: s.category,
          client_name: s.client_name, honorific: s.honorific, subject: s.subject, item_label: s.item_label,
          unit_price: s.unit_price, merged_unit_price: s.merged_unit_price, tax_rate: s.tax_rate, payment_due_days: s.payment_due_days,
          tax_included: s.tax_included,
          issuer_name: s.issuer_name, registration_no: s.registration_no,
          postal_code: s.postal_code, address: s.address, tel: s.tel, email: s.email,
          bank_info: s.bank_info, payment_due_type: s.payment_due_type, default_items: s.default_items,
          # 報酬形態(運送のみ画面に出す): hourly = 時給 / daily = 日給 + 超過時給
          pay_type: s.effective_pay_type, daily_rate: s.daily_rate,
          standard_hours: s.standard_hours&.to_f, overtime_unit_price: s.overtime_unit_price,
          # 超過時給が未入力のときに使われる既定(日給 ÷ 所定時間 × 1.25)。画面のプレースホルダに出す
          default_overtime_unit_price: s.default_overtime_unit_price
        }
      end
    end
  end
end
