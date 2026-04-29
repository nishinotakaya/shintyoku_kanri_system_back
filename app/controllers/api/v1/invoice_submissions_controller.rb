module Api
  module V1
    class InvoiceSubmissionsController < BaseController
      # admin: 全ユーザーの申請を表示。それ以外: 自分の申請のみ。
      # 既定では status=pending を返す。?status=all で全件、?status=approved で承認済のみ。
      # ?kind=invoice|expense でフィルタ可。
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
        scope = scope.where(kind: params[:kind]) if params[:kind].present? && InvoiceSubmission::KINDS.include?(params[:kind].to_s)
        records = scope.order(submitted_at: :desc).includes(:user, :reviewer)
        render json: records.map { |r| serialize(r) }
      end

      def create
        kind = params[:kind].to_s.presence || "invoice"
        kind = "invoice" unless InvoiceSubmission::KINDS.include?(kind)
        record = InvoiceSubmission.new(
          user: current_user,
          year: params[:year].to_i,
          month: params[:month].to_i,
          category: params[:category].to_s.presence || "wings",
          kind: kind,
          note: params[:note].to_s.presence,
          status: "pending"
        )
        record.save!

        # 申請通知 (LINE Messaging API → 西野)。失敗してもレスポンスには影響させない。
        notify_admin_on_create(record)

        render json: serialize(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # admin のみ:
      # - status を渡せば承認/却下、
      # - total_override だけ渡せば「ラボップ宛 税込合計」の保存（status は据え置き）
      def update
        return render(json: { error: "承認権限がありません" }, status: :forbidden) unless current_user.admin?
        record = InvoiceSubmission.find(params[:id])
        attrs = {}

        if params.key?(:status)
          new_status = params[:status].to_s
          return render(json: { error: "不正なステータス" }, status: :unprocessable_entity) unless InvoiceSubmission::STATUSES.include?(new_status)
          attrs[:status] = new_status
          attrs[:reviewer_id] = current_user.id
          attrs[:reviewed_at] = Time.current
        end
        attrs[:note] = params[:note].to_s if params[:note].present?
        if params.key?(:total_override)
          raw = params[:total_override].to_s.gsub(",", "")
          attrs[:total_override] = raw.present? ? raw.to_i : nil
        end
        if params.key?(:item_label_override)
          attrs[:item_label_override] = params[:item_label_override].to_s.presence
        end
        if params.key?(:subject_override)
          attrs[:subject_override] = params[:subject_override].to_s.presence
        end
        if params.key?(:application_date_override)
          raw = params[:application_date_override].to_s
          attrs[:application_date_override] = raw.present? ? Date.iso8601(raw) : nil
        end
        if params.key?(:items_override)
          # 受け取り想定: items_override = [{ label, qty, unit, unit_price, amount }, ...] の配列
          raw = params[:items_override]
          attrs[:items_override] =
            if raw.is_a?(Array) && raw.any?
              raw.map do |it|
                h = it.respond_to?(:to_unsafe_h) ? it.to_unsafe_h : it.to_h
                {
                  "label" => h["label"].to_s,
                  "qty" => h["qty"].to_f,
                  "unit" => h["unit"].to_s.presence || "式",
                  "unit_price" => h["unit_price"].to_i,
                  "amount" => h["amount"].to_i
                }
              end
            end
        end

        record.update!(attrs) if attrs.any?
        render json: serialize(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def notify_admin_on_create(record)
        kind_label = record.kind == "expense" ? "立替金" : "請求書"
        cat_label = { "wings" => "Wings", "living" => "リビング", "techleaders" => "テックリーダーズ", "resystems" => "REシステムズ" }[record.category] || record.category
        text = "📨 #{kind_label}の申請が届きました\n申請者: #{record.user&.display_name}\n対象: #{record.year}年#{record.month}月（#{cat_label}）"
        LineNotifier.push(text)
      rescue => e
        Rails.logger.warn("[InvoiceSubmissions] notify failed: #{e.class}: #{e.message}")
      end

      def serialize(record)
        defaults = approved_defaults_for(record)
        {
          id: record.id,
          user_id: record.user_id,
          user_display_name: record.user&.display_name,
          year: record.year,
          month: record.month,
          year_month: record.year_month,
          category: record.category,
          kind: record.kind,
          status: record.status,
          submitted_at: record.submitted_at&.iso8601,
          reviewed_at: record.reviewed_at&.iso8601,
          reviewer_id: record.reviewer_id,
          reviewer_display_name: record.reviewer&.display_name,
          note: record.note,
          total_override: record.total_override,
          item_label_override: record.item_label_override,
          subject_override: record.subject_override,
          application_date_override: record.application_date_override&.iso8601,
          items_override: record.items_override,
          default_total: defaults[:total],
          default_item_label: defaults[:item_label],
          default_subject: defaults[:subject],
          default_items: defaults[:items],
          default_application_date: defaults[:application_date]
        }
      end

      # approved の時のみ、ラボップモーダル初期表示用に元の請求書計算値を返す
      def approved_defaults_for(record)
        return {} unless record.approved?
        return {} unless record.kind == "invoice"
        calc = InvoicePdfRenderer.new(
          record.user,
          year: record.year, month: record.month, category: record.category
        ).calculation
        surname = record.user.display_name.to_s.split(/[\s　]/).first.to_s
        item_label = "#{surname} 開発業務".strip
        item_label = "開発業務" if item_label == "開発業務"
        {
          total: calc[:total],
          item_label: item_label,
          subject: record.user.invoice_setting_for(record.category || "wings").subject.to_s,
          items: calc[:items],
          application_date: calc[:application_date]&.iso8601
        }
      rescue
        {}
      end
    end
  end
end
