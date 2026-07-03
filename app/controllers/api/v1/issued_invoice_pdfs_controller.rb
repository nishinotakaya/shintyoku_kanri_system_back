module Api
  module V1
    class IssuedInvoicePdfsController < BaseController
      include FreeeReportable
      # admin: 全件 / 自分のみ
      def index
        scope = current_user.admin? ? IssuedInvoicePdf.all : IssuedInvoicePdf.where(user_id: current_user.id)
        scope = scope.where(year: params[:year]) if params[:year].present?
        scope = scope.where(month: params[:month]) if params[:month].present?
        scope = scope.where(category: params[:category]) if params[:category].present?
        records = scope.order(generated_at: :desc).includes(:user)
        render json: records.map { |r| serialize(r) }
      end

      def show
        rec = current_user.admin? ? IssuedInvoicePdf.find(params[:id]) : current_user.issued_invoice_pdfs.find(params[:id])
        render json: serialize(rec)
      end

      # GET /api/v1/issued_invoice_pdfs/:id/download
      def download
        rec = current_user.admin? ? IssuedInvoicePdf.find(params[:id]) : IssuedInvoicePdf.where(user_id: current_user.id).find(params[:id])
        ctype = rec.file_format == "xlsx" ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/pdf"
        send_data rec.file_data, type: ctype, filename: rec.filename, disposition: params[:disposition].presence || "attachment"
      end

      def update
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        rec = IssuedInvoicePdf.find(params[:id])
        attrs = {}
        attrs[:purchase_order_no] = params[:purchase_order_no].to_s.presence if params.key?(:purchase_order_no)
        attrs[:filename] = params[:filename].to_s if params.key?(:filename) && params[:filename].to_s.present?
        attrs[:note] = params[:note].to_s.presence if params.key?(:note)
        rec.update!(attrs) if attrs.any?
        render json: serialize(rec)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def destroy
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        rec = IssuedInvoicePdf.find(params[:id])
        # 削除前にも旧版を退避しておく（誤削除しても revert 元として残す安全網）。
        IssuedInvoicePdfVersion.archive!(rec, reason: "destroy") rescue nil
        rec.destroy!
        head :no_content
      end

      # GET /api/v1/issued_invoice_pdfs/:id/versions
      # 上書き/削除前に自動退避した旧版の一覧（メタのみ、file_data は返さない）。
      def versions
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        rec = IssuedInvoicePdf.find(params[:id])
        render json: rec.versions.map { |v| serialize_version(v) }
      end

      # POST /api/v1/issued_invoice_pdfs/:id/revert  { version_id }
      # 指定した旧版の内容（PDF実体含む）を、この統合PDFへ書き戻す。
      # 書き戻す直前に「現在の版」も退避するので、revert 自体もやり直せる。
      def revert
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        rec = IssuedInvoicePdf.find(params[:id])
        version = rec.versions.find(params[:version_id])
        IssuedInvoicePdf.transaction do
          IssuedInvoicePdfVersion.archive!(rec, reason: "before_revert")
          version.restore_to_source!
        end
        render json: serialize(rec.reload)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "指定した版が見つかりません" }, status: :not_found
      end

      # POST /api/v1/issued_invoice_pdfs/:id/report_to_freee
      # 統合保存済の請求書 PDF も freee に売上計上できるようにする。
      def report_to_freee
        rec = current_user.admin? ? IssuedInvoicePdf.find(params[:id]) : current_user.issued_invoice_pdfs.find(params[:id])
        return render(json: { error: "請求書 (kind=invoice) のみ計上可能" }, status: :unprocessable_entity) unless rec.kind == "invoice"
        return render(json: { error: "金額が 0 円のため計上不可" }, status: :unprocessable_entity) if rec.total_amount.to_i.zero?

        ids = rec.source_submission_ids.is_a?(Array) ? rec.source_submission_ids : (JSON.parse(rec.source_submission_ids.to_s) rescue [])
        sources = InvoiceSubmission.where(id: ids)
        due = sources.map { |s| s.application_date_override }.compact.max ||
              Date.new(rec.year, rec.month, -1)
        subject = "#{rec.year}年#{rec.month}月分 #{rec.category}" +
                  (rec.purchase_order_no.present? ? " (PO: #{rec.purchase_order_no})" : "")

        report_record_to_freee!(
          record: rec,
          invoice_payload: {
            total_amount: rec.total_amount.to_i,
            due_date: due.to_s,
            subject: subject,
            category: rec.category
          }
        )
      end

      # POST /issued_invoice_pdfs/:id/regenerate  { application_date }
      # 統合(発行済み)請求書PDFを、指定した申請日で再生成して上書きする。
      # ※ private 配下に定義されていてルーティング不能だったのを public へ移動（📅申請日ボタンの修正）。
      def regenerate
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        rec = IssuedInvoicePdf.find(params[:id])
        return render(json: { error: "立替金PDFの再生成は未対応です" }, status: :unprocessable_entity) if rec.kind == "expense"

        app_date = params[:application_date].to_s.present? ? (Date.iso8601(params[:application_date].to_s) rescue nil) : nil

        primary_user = rec.user
        ids = rec.source_submission_ids.is_a?(Array) ? rec.source_submission_ids : []
        if ids.any?
          subs = InvoiceSubmission.where(id: ids).includes(:user)
          other_users = subs.map(&:user).uniq.reject { |u| u.id == primary_user.id }
          combined_total = subs.sum { |s| s.total_override.to_i }
          combined_total = rec.total_amount.to_i if combined_total <= 0
        else
          # 元申請が無い統合PDF: 同年月・同カテゴリで work_report を持つ他ユーザーを相手として再構成
          range = Date.new(rec.year, rec.month, 1)
          other_ids = WorkReport.where(category: rec.category)
            .where(work_date: range.beginning_of_month..range.end_of_month)
            .where.not(user_id: primary_user.id).distinct.pluck(:user_id)
          other_users = rec.merged ? User.where(id: other_ids).to_a : []
          combined_total = rec.total_amount.to_i
        end

        # 統合PDF自身に編集明細(items_override)があれば、それで描画（元申請を触らない）。
        if rec.items_override.present?
          renderer = InvoicePdfRenderer.new(
            primary_user, year: rec.year, month: rec.month, category: rec.category,
            application_date: app_date,
            client_name_override: I18n.t("companies.labop.name"),
            issuer_user_override: current_user,
            items_override: rec.items_override, total_override: nil,
            note: rec.note
          )
        else
          renderer = InvoicePdfRenderer.new(
            primary_user, year: rec.year, month: rec.month, category: rec.category,
            application_date: app_date,
            client_name_override: I18n.t("companies.labop.name"),
            issuer_user_override: current_user,
            total_override: (combined_total.positive? ? combined_total : nil),
            note: rec.note,
            merged_users: other_users
          )
        end
        path = renderer.call
        # 上書き前に旧版を退避（誤再生成でも revert で戻せる安全網）
        IssuedInvoicePdfVersion.archive!(rec, reason: "regenerate_application_date") rescue nil
        rec.update!(file_data: File.binread(path), application_date: app_date, generated_at: Time.current)
        render json: serialize(rec)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def serialize_version(v)
        {
          id: v.id,
          issued_invoice_pdf_id: v.issued_invoice_pdf_id,
          purchase_order_no: v.purchase_order_no,
          total_amount: v.total_amount,
          filename: v.filename,
          reason: v.reason,
          original_generated_at: v.original_generated_at&.iso8601,
          archived_at: v.created_at&.iso8601
        }
      end

      def serialize(r)
        ids = r.source_submission_ids
        ids_array = ids.is_a?(Array) ? ids : (ids.is_a?(String) ? (JSON.parse(ids) rescue []) : [])
        # 元申請は 1 回だけロードし、申請者名と統合明細の両方に使い回す（従来は 2 回クエリしていた）
        source_submissions = ids_array.any? ? InvoiceSubmission.where(id: ids_array).includes(:user).to_a : []
        source_user_names = source_submissions.map { |s| s.user&.display_name }.compact.uniq
        {
          id: r.id,
          user_id: r.user_id,
          user_display_name: r.user&.display_name,
          kind: r.kind,
          file_format: r.file_format,
          year: r.year,
          month: r.month,
          category: r.category,
          purchase_order_no: r.purchase_order_no,
          source_submission_ids: ids_array,
          source_user_names: source_user_names,
          items: (r.items_override.presence || (r.kind == "invoice" && source_submissions.any? ? MergedInvoiceItems.build(MergedInvoiceItems.order(source_submissions)) : [])),
          merged: r.merged,
          total_amount: r.total_amount,
          filename: r.filename,
          note: r.note,
          application_date: r.application_date&.iso8601,
          generated_at: r.generated_at&.iso8601,
          freee_deal_id: r.freee_deal_id,
          freee_reported_at: r.freee_reported_at&.iso8601
        }
      end
    end
  end
end
