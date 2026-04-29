module Api
  module V1
    class EmailsController < BaseController
      # POST /api/v1/emails/labop_draft
      # ラボップ宛 請求書 + 立替金 送付メールの件名/本文 下書きを生成
      def labop_draft
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        invoice = InvoiceSubmission.find(params[:invoice_submission_id])
        expense = InvoiceSubmission.find_by(id: params[:expense_submission_id])
        total = invoice.total_override || begin
          calc = InvoicePdfRenderer.new(invoice.user, year: invoice.year, month: invoice.month, category: invoice.category).calculation
          calc[:total]
        end
        ctx = {
          recipient_name: params[:recipient_name].presence || "大隅",
          year: invoice.year, month: invoice.month,
          total: total,
          applicant_name: invoice.user&.display_name,
          sender_name: current_user.display_name,
          extra_attachments: params[:extra_count].to_i > 0
        }
        render json: EmailDrafter.draft(kind: :labop_invoice, context: ctx)
      end

      # POST /api/v1/emails/labop_send
      # 添付3つ (ラボップ宛請求書PDF, 立替金PDF, 立替金Excel) + 任意添付 を送信。
      # OUTBOUND_TEST_RECIPIENT が設定されていればそこへ転送。
      def labop_send
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        invoice = InvoiceSubmission.find(params[:invoice_submission_id])
        expense = InvoiceSubmission.find_by(id: params[:expense_submission_id])
        return render(json: { error: "請求書 submission が見つかりません" }, status: :unprocessable_entity) unless invoice&.approved?

        attachments = []
        # ラボップ宛 請求書 PDF
        invoice_pdf = InvoicePdfRenderer.new(
          invoice.user,
          year: invoice.year, month: invoice.month, category: invoice.category,
          client_name_override: "株式会社ラボップ",
          issuer_user_override: current_user,
          total_override: invoice.total_override,
          item_label_override: invoice.item_label_override,
          subject_override: invoice.subject_override,
          items_override: invoice.items_override,
          application_date: invoice.application_date_override
        ).call
        attachments << { filename: invoice_filename(invoice), content_type: "application/pdf", body: File.binread(invoice_pdf) }

        if expense&.approved?
          # 立替金 PDF (ラボップ宛・西野発行)
          exp_pdf = ExpensePdfRenderer.new(
            expense.user, year: expense.year, month: expense.month, category: expense.category,
            client_name_override: "株式会社ラボップ", issuer_user_override: current_user,
            application_date: expense.application_date_override
          ).call
          attachments << { filename: expense_pdf_filename(expense), content_type: "application/pdf", body: File.binread(exp_pdf) }
          # 立替金 Excel
          exp_xlsx = ExpenseExporter.new(
            expense.user, year: expense.year, month: expense.month, category: expense.category,
            client_name_override: "株式会社ラボップ", issuer_user_override: current_user,
            application_date: expense.application_date_override
          ).call
          attachments << { filename: expense_xlsx_filename(expense), content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(exp_xlsx) }
        end

        # 任意添付 (multipart で送られた追加ファイル)
        Array(params[:extra_files]).each do |f|
          next unless f.respond_to?(:read)
          attachments << { filename: f.original_filename, content_type: f.content_type, body: f.read }
        end

        msg_id = GmailSender.new(user: current_user).send_mail(
          to: params[:to].presence || "k-osumi@rabop.jp",
          subject: params[:subject].to_s,
          body: params[:body].to_s,
          attachments: attachments,
          from_name: current_user.display_name
        )
        actual = ENV["OUTBOUND_TEST_RECIPIENT"].presence || (params[:to].presence || "k-osumi@rabop.jp")
        render json: { ok: true, message_id: msg_id, sent_to: actual }
      rescue => e
        Rails.logger.error("[labop_send] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/emails/purchase_order_draft
      def purchase_order_draft
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        ctx = {
          subject: params[:subject].to_s.presence,
          order_no: params[:order_no].to_s.presence,
          sender_name: current_user.display_name,
          recipient_name: "川村 卓也"
        }
        render json: EmailDrafter.draft(kind: :purchase_order, context: ctx)
      end

      # POST /api/v1/emails/purchase_order_send
      # multipart で発注書 PDF + 任意添付を受け取って川村宛に送信
      def purchase_order_send
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        kawamura = User.find_by(email: "calmdownyourlife@gmail.com")
        to = params[:to].presence || kawamura&.email
        return render(json: { error: "宛先が解決できません" }, status: :unprocessable_entity) if to.blank?

        attachments = []
        Array(params[:files]).each do |f|
          next unless f.respond_to?(:read)
          attachments << { filename: f.original_filename, content_type: f.content_type, body: f.read }
        end
        msg_id = GmailSender.new(user: current_user).send_mail(
          to: to,
          subject: params[:subject].to_s,
          body: params[:body].to_s,
          attachments: attachments,
          from_name: current_user.display_name
        )
        actual = ENV["OUTBOUND_TEST_RECIPIENT"].presence || to
        render json: { ok: true, message_id: msg_id, sent_to: actual }
      rescue => e
        Rails.logger.error("[purchase_order_send] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def invoice_filename(s)
        surname = s.user.display_name.to_s.split(/[\s　]/).first
        "#{surname}_請求書_#{s.year}年_#{s.month}月分_株式会社ラボップ.pdf"
      end
      def expense_pdf_filename(s)
        surname = s.user.display_name.to_s.split(/[\s　]/).first
        "#{surname}_立替金_#{s.year}年_#{s.month}月分_株式会社ラボップ.pdf"
      end
      def expense_xlsx_filename(s)
        surname = s.user.display_name.to_s.split(/[\s　]/).first
        "#{surname}_立替金_#{s.year}年_#{s.month}月分_株式会社ラボップ.xlsx"
      end
    end
  end
end
