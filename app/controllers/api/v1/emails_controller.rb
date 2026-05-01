module Api
  module V1
    class EmailsController < BaseController
      # メール件名・本文・添付ファイル名 用のカテゴリラベル
      # 「wings」→ 社内的には「Tama」と呼ぶ運用なのでメール表示は「Tama」
      # config/locales/invoice_submission/ja.yml に定義
      CATEGORY_LABELS = I18n.t("invoice_submission.categories").stringify_keys.freeze

      # POST /api/v1/emails/labop_draft
      # 複数の承認済 invoice + expense をまとめて送付するメールの件名/本文 下書き
      def labop_draft
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        invoice_ids = Array(params[:invoice_submission_ids]).map(&:to_i).reject(&:zero?)
        expense_ids = Array(params[:expense_submission_ids]).map(&:to_i).reject(&:zero?)
        invoices = InvoiceSubmission.where(id: invoice_ids).where(kind: "invoice").approved.includes(:user)
        expenses = InvoiceSubmission.where(id: expense_ids).where(kind: "expense").approved.includes(:user)
        invoice_total = invoices.sum { |i| i.total_override || invoice_calc_total(i) }
        expense_total = expenses.sum { |e| expense_calc_total(e) }
        ctx = {
          recipient_name: params[:recipient_name].presence || "#{I18n.t("companies.labop.name")} #{I18n.t("companies.labop.honorific_default")}",
          year: invoices.first&.year || expenses.first&.year,
          month: invoices.first&.month || expenses.first&.month,
          category_label: CATEGORY_LABELS[(invoices.first&.category || expenses.first&.category).to_s] || (invoices.first&.category || expenses.first&.category).to_s,
          total: invoice_total,
          expense_total: expense_total,
          grand_total: invoice_total + expense_total,
          applicant_name: (invoices + expenses).map { |s| s.user&.display_name }.compact.uniq.join("、"),
          sender_name: current_user.display_name,
          extra_attachments: params[:extra_count].to_i > 0,
          invoice_count: invoices.size,
          expense_count: expenses.size
        }
        render json: EmailDrafter.draft(kind: :labop_invoice, context: ctx)
      end

      def invoice_calc_total(invoice)
        InvoicePdfRenderer.new(invoice.user, year: invoice.year, month: invoice.month, category: invoice.category).calculation[:total]
      rescue
        0
      end

      def expense_calc_total(submission)
        period = submission.user.period_for(submission.year, submission.month)
        submission.user.expenses.in_range(period).where(category: submission.category).sum(:amount).to_i
      rescue
        0
      end

      # POST /api/v1/emails/labop_send
      # 複数の承認済 invoice + 複数の承認済 expense を一括添付してラボップ宛送信。
      # 各 invoice → ラボップ宛 PDF / 各 expense → PDF + Excel
      # 宛先は params[:to] をそのまま使用 (Frontend が選んだ送り先を尊重)。
      def labop_send
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        # 添付タイプ別に id 配列を受ける（旧 invoice_submission_ids/expense_submission_ids も後方互換で受理）
        invoice_pdf_ids = Array(params[:invoice_pdf_submission_ids].presence || params[:invoice_submission_ids]).map(&:to_i).reject(&:zero?)
        wr_xlsx_ids = Array(params[:work_report_xlsx_submission_ids].presence || params[:invoice_submission_ids]).map(&:to_i).reject(&:zero?)
        expense_pdf_ids = Array(params[:expense_pdf_submission_ids].presence || params[:expense_submission_ids]).map(&:to_i).reject(&:zero?)
        expense_xlsx_ids = Array(params[:expense_xlsx_submission_ids].presence || params[:expense_submission_ids]).map(&:to_i).reject(&:zero?)
        invoices_for_pdf = InvoiceSubmission.where(id: invoice_pdf_ids).where(kind: "invoice").approved
        invoices_for_wr = InvoiceSubmission.where(id: wr_xlsx_ids).where(kind: "invoice").approved
        expense_pdfs = InvoiceSubmission.where(id: expense_pdf_ids).where(kind: "expense").approved
        expense_xlsxs = InvoiceSubmission.where(id: expense_xlsx_ids).where(kind: "expense").approved
        if invoices_for_pdf.empty? && invoices_for_wr.empty? && expense_pdfs.empty? && expense_xlsxs.empty?
          return render(json: { error: "送付対象が空です" }, status: :unprocessable_entity)
        end

        attachments = []
        # 申請日: 申請者の application_date_override は申請者が「申請した日」が入りがちなので
        # ラボップ宛発行時は override を使わず、発行者(西野)の月別設定（無ければ末日）を採用する
        invoices_for_pdf.each do |invoice|
          invoice_pdf = InvoicePdfRenderer.new(
            invoice.user,
            year: invoice.year, month: invoice.month, category: invoice.category,
            client_name_override: I18n.t("companies.labop.name"),
            issuer_user_override: current_user,
            total_override: invoice.total_override,
            item_label_override: invoice.item_label_override,
            subject_override: invoice.subject_override,
            items_override: invoice.items_override,
            note: invoice.note
          ).call
          attachments << { filename: invoice_filename(invoice), content_type: "application/pdf", body: File.binread(invoice_pdf) }
        end
        invoices_for_wr.each do |invoice|
          # 業務報告 Excel (申請者データそのまま) — checkbox で個別に選択可能
          wr_path = WorkReportExporter.new(invoice.user, year: invoice.year, month: invoice.month, category: invoice.category).call
          attachments << { filename: work_report_filename(invoice), content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(wr_path) }
        end
        # 立替金合計 0 円の月は PDF/Excel どちらも添付しない（空の精算書を送らない）
        expense_pdfs.each do |expense|
          next if expense_calc_total(expense) <= 0
          exp_pdf = ExpensePdfRenderer.new(
            expense.user, year: expense.year, month: expense.month, category: expense.category,
            client_name_override: I18n.t("companies.labop.name"), issuer_user_override: current_user
          ).call
          attachments << { filename: expense_pdf_filename(expense), content_type: "application/pdf", body: File.binread(exp_pdf) }
        end
        expense_xlsxs.each do |expense|
          next if expense_calc_total(expense) <= 0
          exp_xlsx = ExpenseExporter.new(
            expense.user, year: expense.year, month: expense.month, category: expense.category,
            client_name_override: I18n.t("companies.labop.name"), issuer_user_override: current_user
          ).call
          attachments << { filename: expense_xlsx_filename(expense), content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(exp_xlsx) }
        end

        Array(params[:extra_files]).each do |f|
          next unless f.respond_to?(:read)
          attachments << { filename: f.original_filename, content_type: f.content_type, body: f.read }
        end

        to_value = params[:to].to_s.presence || "k-osumi@rabop.jp"
        msg_id = GmailSender.new(user: current_user).send_mail(
          to: to_value,
          subject: params[:subject].to_s,
          body: params[:body].to_s,
          attachments: attachments,
          from_name: current_user.display_name
        )
        render json: { ok: true, message_id: msg_id, sent_to: to_value, attachments: attachments.map { |a| a[:filename] } }
      rescue => e
        Rails.logger.error("[labop_send] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/emails/self_invoice_draft
      # ログイン中ユーザ自身の請求書 + (任意で立替金) を任意宛先に送付するメール下書き
      def self_invoice_draft
        year, month = parse_month
        cat = params[:category].presence || "wings"
        include_expense_raw = ActiveModel::Type::Boolean.new.cast(params[:include_expense])
        invoice_total = invoice_calc_total_for(current_user, year, month, cat)
        available_expense_total = expense_calc_total_for(current_user, year, month, cat)
        # 立替金が 0 円なら強制的に同梱しない
        include_expense = include_expense_raw && available_expense_total > 0
        expense_total = include_expense ? available_expense_total : 0
        ctx = {
          recipient_name: params[:recipient_name].presence || "御中",
          year: year, month: month,
          category_label: CATEGORY_LABELS[cat] || cat,
          total: invoice_total,
          expense_total: expense_total,
          grand_total: invoice_total + expense_total,
          include_expense: include_expense,
          sender_name: current_user.display_name
        }
        drafted = EmailDrafter.draft(kind: :self_invoice, context: ctx)
        render json: drafted.merge(available_expense_total: available_expense_total)
      end

      # POST /api/v1/emails/self_invoice_send
      # ログイン中ユーザ自身の請求書 PDF + (任意で立替金 PDF/Excel) を任意宛先に送付
      def self_invoice_send
        year, month = parse_month
        cat = params[:category].presence || "wings"
        return render(json: { error: "宛先が空です" }, status: :unprocessable_entity) if params[:to].to_s.strip.empty?

        # 添付タイプ別フラグ（後方互換: include_expense=true なら expense_pdf/xlsx 両方デフォルト on）
        cast_bool = ->(v, default) { v.nil? ? default : ActiveModel::Type::Boolean.new.cast(v) }
        legacy_include_expense = ActiveModel::Type::Boolean.new.cast(params[:include_expense])
        include_invoice_pdf = cast_bool.call(params[:include_invoice_pdf], true)
        include_expense_pdf = cast_bool.call(params[:include_expense_pdf], legacy_include_expense)
        include_expense_xlsx = cast_bool.call(params[:include_expense_xlsx], legacy_include_expense)

        # 立替金が 0 円なら強制的に同梱しない
        expense_total = expense_calc_total_for(current_user, year, month, cat)
        include_expense_pdf = false if expense_total <= 0
        include_expense_xlsx = false if expense_total <= 0

        if !include_invoice_pdf && !include_expense_pdf && !include_expense_xlsx
          return render(json: { error: "送付対象の添付が選択されていません" }, status: :unprocessable_entity)
        end

        surname = current_user.display_name.to_s.split(/[\s　]/).first
        cat_label = CATEGORY_LABELS[cat] || cat
        attachments = []
        labop_name = I18n.t("companies.labop.name")

        if include_invoice_pdf
          invoice_pdf = InvoicePdfRenderer.new(current_user, year: year, month: month, category: cat,
            application_date: parse_application_date,
            client_name_override: labop_name).call
          attachments << { filename: "#{surname}_#{cat_label}_請求書_#{year}年_#{month}月分.pdf",
                           content_type: "application/pdf", body: File.binread(invoice_pdf) }
        end

        if include_expense_pdf
          exp_pdf = ExpensePdfRenderer.new(current_user, year: year, month: month, category: cat,
            application_date: parse_application_date,
            client_name_override: labop_name).call
          attachments << { filename: "#{surname}_#{cat_label}_立替金_#{year}年_#{month}月分.pdf",
                           content_type: "application/pdf", body: File.binread(exp_pdf) }
        end

        if include_expense_xlsx
          exp_xlsx = ExpenseExporter.new(current_user, year: year, month: month, category: cat,
            application_date: parse_application_date,
            client_name_override: labop_name).call
          attachments << { filename: "#{surname}_#{cat_label}_立替金_#{year}年_#{month}月分.xlsx",
                           content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                           body: File.binread(exp_xlsx) }
        end

        Array(params[:extra_files]).each do |f|
          next unless f.respond_to?(:read)
          attachments << { filename: f.original_filename, content_type: f.content_type, body: f.read }
        end

        msg_id = GmailSender.new(user: current_user).send_mail(
          to: params[:to], subject: params[:subject].to_s, body: params[:body].to_s,
          attachments: attachments, from_name: current_user.display_name
        )
        render json: { ok: true, message_id: msg_id, sent_to: params[:to], attachments: attachments.map { |a| a[:filename] } }
      rescue => e
        Rails.logger.error("[self_invoice_send] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def invoice_calc_total_for(user, year, month, cat)
        InvoicePdfRenderer.new(user, year: year, month: month, category: cat).calculation[:total]
      rescue
        0
      end
      def expense_calc_total_for(user, year, month, cat)
        period = user.period_for(year, month)
        user.expenses.in_range(period).where(category: cat).sum(:amount).to_i
      rescue
        0
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
      def work_report_filename(s)
        surname = s.user.display_name.to_s.split(/[\s　]/).first
        cat_label = { "wings" => "Wings", "living" => "リビング", "techleaders" => "テックリーダーズ", "resystems" => "REシステムズ" }[s.category] || s.category.to_s
        "#{surname}_#{cat_label}_業務報告書_#{s.year}年_#{s.month}月分.xlsx"
      end
    end
  end
end
