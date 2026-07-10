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
        issued_pdf_ids = Array(params[:issued_invoice_pdf_ids]).map(&:to_i).reject(&:zero?)
        invoices = InvoiceSubmission.where(id: invoice_ids).where(kind: "invoice").approved.includes(:user, :received_purchase_order)
        expenses = InvoiceSubmission.where(id: expense_ids).where(kind: "expense").approved.includes(:user)
        issued_pdfs = IssuedInvoicePdf.where(id: issued_pdf_ids)
        invoice_total = invoices.sum { |i| i.total_override || invoice_calc_total(i) }
        expense_total = expenses.sum { |e| expense_calc_total(e) }
        issued_invoice_total = issued_pdfs.where(kind: "invoice").sum(:total_amount).to_i
        issued_expense_total = issued_pdfs.where(kind: "expense").sum(:total_amount).to_i
        breakdown_items = build_labop_breakdown_items(invoices, expenses, issued_pdfs)
        first_year = invoices.first&.year || expenses.first&.year || issued_pdfs.first&.year
        first_month = invoices.first&.month || expenses.first&.month || issued_pdfs.first&.month
        first_cat = invoices.first&.category || expenses.first&.category || issued_pdfs.first&.category
        ctx = {
          recipient_name: params[:recipient_name].presence || "#{I18n.t("companies.labop.name")} #{I18n.t("companies.labop.honorific_default")}",
          year: first_year,
          month: first_month,
          category_label: CATEGORY_LABELS[first_cat.to_s] || first_cat.to_s,
          total: invoice_total + issued_invoice_total,
          expense_total: expense_total + issued_expense_total,
          grand_total: invoice_total + issued_invoice_total + expense_total + issued_expense_total,
          applicant_name: (invoices + expenses).map { |s| s.user&.display_name }.compact.uniq.join("、"),
          sender_name: current_user.display_name,
          extra_attachments: params[:extra_count].to_i > 0,
          invoice_count: invoices.size + issued_pdfs.where(kind: "invoice").count,
          expense_count: expenses.size + issued_pdfs.where(kind: "expense").count,
          breakdown_items: breakdown_items
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
        submission.user.expenses.in_range(period).where(category: submission.category, company_burden: true).sum(:amount).to_i
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
        # 保存済 統合 PDF (IssuedInvoicePdf): バイナリをそのまま添付
        issued_pdf_ids = Array(params[:issued_invoice_pdf_ids]).map(&:to_i).reject(&:zero?)
        issued_pdfs = IssuedInvoicePdf.where(id: issued_pdf_ids)
        # 統合(保存済) 立替金 PDF が選ばれていたら、その元になった expense submission も
        # Excel 対象に自動で展開する（運用上 PDF とセットで per-user Excel が必要なため）。
        issued_pdfs.where(kind: "expense").each do |ip|
          raw = ip.source_submission_ids
          src = if raw.is_a?(Array)
            raw
          elsif raw.is_a?(String) && raw.present?
            (JSON.parse(raw) rescue [])
          else
            []
          end
          expense_xlsx_ids += Array(src).map(&:to_i)
        end
        expense_xlsx_ids = expense_xlsx_ids.uniq.reject(&:zero?)
        expense_xlsxs = InvoiceSubmission.where(id: expense_xlsx_ids).where(kind: "expense").approved
        if invoices_for_pdf.empty? && invoices_for_wr.empty? && expense_pdfs.empty? && expense_xlsxs.empty? && issued_pdfs.empty?
          return render(json: { error: "送付対象が空です" }, status: :unprocessable_entity)
        end

        attachments = []
        # 申請日: 編集UIで設定した application_date_override があればそれを採用（PDF左上の申請日に反映）。
        # 未設定(nil)なら各レンダラ側で発行者(西野)の月別設定（無ければ末日）にフォールバックする。

        # PO ごとにグルーピング: 同じ PO に複数申請あり (ORD-010014 西野+川村 等) → 1 PDF にマージ
        invoices_grouped = invoices_for_pdf.to_a.group_by(&:received_purchase_order_id)
        invoices_grouped.each do |po_id, group|
          if po_id.present? && group.size >= 2
            # マージ請求書 (例: ORD-010014 西野+川村)
            # items_override は使わず work_reports ベースで全ユーザー iterate
            # total_override は各 submission を合算
            primary = group.first
            others = group.drop(1).map(&:user)
            effective_no = primary.purchase_order_no_override.presence || primary.received_purchase_order&.order_no
            po_line = effective_no.present? ? "注文番号: #{effective_no}" : nil
            composed_note = [ po_line, primary.note ].compact.reject(&:blank?).join("\n")
            combined_total = group.sum { |s| s.total_override.to_i }
            combined_total = nil if combined_total <= 0
            invoice_pdf = InvoicePdfRenderer.new(
              primary.user,
              year: primary.year, month: primary.month, category: primary.category,
              application_date: group.map(&:application_date_override).compact.first,
              client_name_override: I18n.t("companies.labop.name"),
              issuer_user_override: current_user,
              total_override: combined_total,
              item_label_override: primary.item_label_override,
              subject_override: primary.subject_override,
              items_override: nil, # 集約時は明細を全ユーザーの work_reports から自動生成
              note: composed_note.presence,
              merged_users: others
            ).call
            surnames = group.map(&:user).map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
            cat_label = CATEGORY_LABELS[primary.category.to_s] || primary.category.to_s
            fname = "#{cat_label}_#{surnames.presence || '集約'}_請求書_#{primary.year}年_#{primary.month}月分.pdf"
            attachments << { filename: fname, content_type: "application/pdf", body: File.binread(invoice_pdf) }
          else
            # 単一申請（PO なし or PO に1件）→ 個別 PDF
            group.each do |invoice|
              effective_no = invoice.purchase_order_no_override.presence || invoice.received_purchase_order&.order_no
              po_line = effective_no.present? ? "注文番号: #{effective_no}" : nil
              composed_note = [ po_line, invoice.note ].compact.reject(&:blank?).join("\n")
              invoice_pdf = InvoicePdfRenderer.new(
                invoice.user,
                year: invoice.year, month: invoice.month, category: invoice.category,
                application_date: invoice.application_date_override,
                client_name_override: I18n.t("companies.labop.name"),
                issuer_user_override: current_user,
                total_override: invoice.total_override,
                item_label_override: invoice.item_label_override,
                subject_override: invoice.subject_override,
                items_override: invoice.items_override,
                note: composed_note.presence
              ).call
              attachments << { filename: invoice_filename(invoice), content_type: "application/pdf", body: File.binread(invoice_pdf) }
            end
          end
        end
        invoices_for_wr.each do |invoice|
          # 業務報告 Excel (申請者データそのまま) — checkbox で個別に選択可能
          wr_path = WorkReportExporter.new(invoice.user, year: invoice.year, month: invoice.month, category: invoice.category).call
          attachments << { filename: work_report_filename(invoice), content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(wr_path) }
        end
        # 立替金 PDF/Excel の振り分け（案 A、金額マイナスベース判定）:
        # - 各ユーザーの expense のうち amount < 0 のもの = 相殺（西野シェアラウンジ補填等）→ 別建て PDF/Excel
        # - amount > 0 のもの = 通常立替金 → (year×month×category) で集約 1 通

        # ----- 立替金 PDF（通常: amount > 0 を集約） -----
        expense_pdfs.to_a.group_by { |s| [ s.year, s.month, s.category ] }.each do |(y, m, c), subs|
          users = subs.map(&:user).uniq
          total = users.sum { |u|
            u.expenses.in_range(u.period_for(y, m)).where(category: c, company_burden: true).where("amount > 0").sum(:amount).to_i
          }
          next if total <= 0
          primary = users.first
          others = users.drop(1)
          exp_pdf = ExpensePdfRenderer.new(
            primary, year: y, month: m, category: c,
            application_date: subs.map(&:application_date_override).compact.first,
            client_name_override: I18n.t("companies.labop.name"), issuer_user_override: current_user,
            merged_users: others, mode: :positive
          ).call
          surnames = users.map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
          cat_label = CATEGORY_LABELS[c.to_s] || c.to_s
          fname = "#{cat_label}_#{surnames.presence || '集約'}_立替金_#{y}年_#{m}月分.pdf"
          attachments << { filename: fname, content_type: "application/pdf", body: File.binread(exp_pdf) }
        end

        # ----- 立替金 PDF（相殺: amount < 0 を申請者ごとに別建て） -----
        expense_pdfs.to_a.each do |s|
          neg_total = s.user.expenses.in_range(s.user.period_for(s.year, s.month))
            .where(category: s.category, company_burden: true).where("amount < 0").sum(:amount).to_i
          next if neg_total >= 0
          exp_pdf = ExpensePdfRenderer.new(
            s.user, year: s.year, month: s.month, category: s.category,
            application_date: s.application_date_override,
            client_name_override: I18n.t("companies.labop.name"), issuer_user_override: current_user,
            mode: :negative
          ).call
          surname = s.user.display_name.to_s.split(/[\s　]/).first.to_s
          cat_label = CATEGORY_LABELS[s.category.to_s] || s.category.to_s
          fname = "#{cat_label}_#{surname}_立替金_相殺_#{s.year}年_#{s.month}月分.pdf"
          attachments << { filename: fname, content_type: "application/pdf", body: File.binread(exp_pdf) }
        end

        # ----- 立替金 Excel（通常: 集約） -----
        # 立替金 Excel（通常: amount > 0）はユーザーごとに別ファイル出力する。
        # 交通費の精算は申請者ごとに 1 シート単位で確認したい運用のため、PDF と違い Excel はマージしない。
        expense_xlsxs.to_a.each do |s|
          user = s.user
          # シェアラウンジ等 (excel_excluded=true) は Excel から除外
          total = user.expenses.in_range(user.period_for(s.year, s.month))
            .where(category: s.category, company_burden: true, excel_excluded: false)
            .where("amount > 0").sum(:amount).to_i
          next if total <= 0
          exp_xlsx = ExpenseExporter.new(
            user, year: s.year, month: s.month, category: s.category,
            application_date: s.application_date_override,
            client_name_override: I18n.t("companies.labop.name"), issuer_user_override: current_user,
            mode: :positive
          ).call
          surname = user.display_name.to_s.split(/[\s　]/).first.to_s
          cat_label = CATEGORY_LABELS[s.category.to_s] || s.category.to_s
          fname = "#{cat_label}_#{surname}_立替金_#{s.year}年_#{s.month}月分.xlsx"
          attachments << { filename: fname, content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(exp_xlsx) }
        end

        # ----- 立替金 Excel（相殺: 別建て） -----
        expense_xlsxs.to_a.each do |s|
          neg_total = s.user.expenses.in_range(s.user.period_for(s.year, s.month))
            .where(category: s.category, company_burden: true, excel_excluded: false).where("amount < 0").sum(:amount).to_i
          next if neg_total >= 0
          exp_xlsx = ExpenseExporter.new(
            s.user, year: s.year, month: s.month, category: s.category,
            application_date: s.application_date_override,
            client_name_override: I18n.t("companies.labop.name"), issuer_user_override: current_user,
            mode: :negative
          ).call
          surname = s.user.display_name.to_s.split(/[\s　]/).first.to_s
          cat_label = CATEGORY_LABELS[s.category.to_s] || s.category.to_s
          fname = "#{cat_label}_#{surname}_立替金_相殺_#{s.year}年_#{s.month}月分.xlsx"
          attachments << { filename: fname, content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(exp_xlsx) }
        end

        # 保存済み 統合 PDF: 既に生成済みのバイナリをそのまま添付
        issued_pdfs.each do |ip|
          ctype = ip.file_format == "xlsx" ?
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" :
            "application/pdf"
          attachments << { filename: ip.filename, content_type: ctype, body: ip.file_data }
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
          attachments << { filename: "#{cat_label}_#{surname}_請求書_#{year}年_#{month}月分.pdf",
                           content_type: "application/pdf", body: File.binread(invoice_pdf) }
        end

        if include_expense_pdf
          exp_pdf = ExpensePdfRenderer.new(current_user, year: year, month: month, category: cat,
            application_date: parse_application_date,
            client_name_override: labop_name).call
          attachments << { filename: "#{cat_label}_#{surname}_立替金_#{year}年_#{month}月分.pdf",
                           content_type: "application/pdf", body: File.binread(exp_pdf) }
        end

        if include_expense_xlsx
          exp_xlsx = ExpenseExporter.new(current_user, year: year, month: month, category: cat,
            application_date: parse_application_date,
            client_name_override: labop_name).call
          attachments << { filename: "#{cat_label}_#{surname}_立替金_#{year}年_#{month}月分.xlsx",
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
        user.expenses.in_range(period).where(category: cat, company_burden: true).sum(:amount).to_i
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

      # POST /api/v1/emails/purchase_order_bulk_draft
      # 複数の発注書を一括送付するメールの件名/本文 下書き
      # params: items[] (subject, order_no, period_start, period_end, total_amount)
      def purchase_order_bulk_draft
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        items = Array(params[:items]).map do |it|
          {
            subject: it[:subject].to_s,
            order_no: it[:order_no].to_s,
            category: it[:category].to_s,
            period_start: it[:period_start].to_s,
            period_end: it[:period_end].to_s,
            total_amount: it[:total_amount].to_i,
            hours_per_cycle: it[:hours_per_cycle].to_i,
            # 月額・時給はフロントで税抜/税込両方を確定済みで送ってくる（base_monthly のレコード混在問題を回避）
            monthly_tax_inc: it[:monthly_tax_inc].to_i,
            monthly_tax_exc: it[:monthly_tax_exc].to_i,
            hourly_tax_inc: it[:hourly_tax_inc].to_i,
            hourly_tax_exc: it[:hourly_tax_exc].to_i
          }
        end
        ctx = {
          items: items,
          sender_name: current_user.display_name,
          recipient_name: "川村 卓也"
        }
        render json: EmailDrafter.draft(kind: :purchase_order_bulk, context: ctx)
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

      # POST /api/v1/emails/payment_notice_draft
      # 振込通知 (支払通知書) メールの件名/本文 下書き
      # params: invoice_submission_ids[], paid_on (YYYY-MM-DD), recipient_name?, to?
      def payment_notice_draft
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        ids = Array(params[:invoice_submission_ids]).map(&:to_i).reject(&:zero?)
        subs = InvoiceSubmission.where(id: ids).includes(:user, :received_purchase_order)
        # 振込先・宛名は先頭申請の申請者で解決するため、受取人が混在すると別人の口座宛て通知になる
        if subs.map(&:user_id).uniq.size > 1
          return render(json: { error: "申請者が異なる申請が混在しています。振込通知は受取人ごとに分けて送ってください。" }, status: :unprocessable_entity)
        end
        breakdown_items = subs.map do |s|
          surname = s.user&.display_name.to_s.split(/[\s　]/).first.to_s
          po = s.purchase_order_no_override.presence || s.received_purchase_order&.order_no
          po_label = po.present? ? "#{po} " : ""
          cat_label = CATEGORY_LABELS[s.category.to_s] || s.category.to_s
          kind_label = s.kind == "expense" ? "立替金" : "請求書"
          amt = s.total_override.to_i.nonzero? || calc_total_for_submission(s)
          {
            label: "#{po_label}#{surname} #{s.year}年#{s.month}月 #{cat_label} #{kind_label}",
            amount: amt
          }
        end
        grand_total = breakdown_items.sum { |it| it[:amount].to_i }
        first = subs.first
        # 宛名が指定されていなければ、対象 submission の user 名を採用 (e.g., 川村 卓也)
        default_recipient = first&.user&.display_name
        # お振込先: 受取人(申請者)の請求書設定 bank_info を自動で載せる。外部APIは不要(保存値を使う)。
        # 複数申請でも受取人は同一想定なので先頭申請の申請者・カテゴリで解決する。
        payee_bank_info = first&.user&.invoice_setting_for(first.category)&.bank_info.to_s
        ctx = {
          recipient_name: params[:recipient_name].presence || default_recipient,
          paid_on: params[:paid_on].to_s.presence || Date.current.iso8601,
          grand_total: grand_total,
          breakdown_items: breakdown_items,
          sender_name: current_user.display_name,
          bank_info: payee_bank_info,
          year: first&.year,
          month: first&.month
        }
        render json: EmailDrafter.draft(kind: :payment_notice, context: ctx)
      end

      # POST /api/v1/emails/payment_notice_send
      # 振込通知メールを送信し、対象 invoice_submissions の paid_at を更新
      # 添付: 各 submission につき 支払通知書 PDF (請求書テンプレ流用、タイトルだけ差替)
      def payment_notice_send
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        ids = Array(params[:invoice_submission_ids]).map(&:to_i).reject(&:zero?)
        return render(json: { error: "対象がありません" }, status: :unprocessable_entity) if ids.empty?
        to_value = params[:to].to_s.strip
        return render(json: { error: "宛先が空です" }, status: :unprocessable_entity) if to_value.empty?

        paid_on = begin
          params[:paid_on].present? ? Date.parse(params[:paid_on].to_s) : Date.current
        rescue ArgumentError
          Date.current
        end

        # 支払通知書 PDF: 川村さんの請求書をそのまま使い、タイトルだけ「支払通知書」に差替
        # (発行者=川村、振込先=川村の口座、宛先=川村側の請求書クライアント のまま)
        subs = InvoiceSubmission.where(id: ids).includes(:user, :received_purchase_order)
        # 受取人が混在すると別人の口座宛て通知＋paid_at一括更新になるため単一申請者のみ許可
        if subs.map(&:user_id).uniq.size > 1
          return render(json: { error: "申請者が異なる申請が混在しています。振込通知は受取人ごとに分けて送ってください。" }, status: :unprocessable_entity)
        end
        attachments = []
        subs.each do |s|
          surname = s.user&.display_name.to_s.split(/[\s　]/).first.to_s
          cat_label = CATEGORY_LABELS[s.category.to_s] || s.category.to_s

          if s.kind == "expense"
            # 立替金の支払通知書 PDF (ExpensePdfRenderer 経由)
            exp_pdf = ExpensePdfRenderer.new(
              s.user, year: s.year, month: s.month, category: s.category,
              issuer_user_override: current_user,
              client_name_override: s.user.display_name,
              title_override: "支払通知書",
              application_date: paid_on # 発行日=振込済にした当日
            ).call
            fname = "#{cat_label}_#{surname.presence || '通知'}_支払通知書_立替金_#{s.year}年_#{s.month}月分.pdf"
            attachments << { filename: fname, content_type: "application/pdf", body: File.binread(exp_pdf) }
            next
          end

          # 通常の請求書ベース 支払通知書
          effective_no = s.purchase_order_no_override.presence || s.received_purchase_order&.order_no
          po_line = effective_no.present? ? "注文番号: #{effective_no}" : nil
          composed_note = [ po_line, s.note ].compact.reject(&:blank?).join("\n")
          pdf_path = InvoicePdfRenderer.new(
            s.user,
            year: s.year, month: s.month, category: s.category,
            total_override: s.total_override,
            item_label_override: s.item_label_override,
            subject_override: s.subject_override,
            items_override: s.items_override,
            note: composed_note.presence,
            title_override: "支払通知書",
            # 支払通知書は「支払い側」が「受領側」に出すもの。
            # 発行者(及び印影)は payer=current_user(西野)、宛名(client)は payee=s.user(川村)。
            issuer_user_override: current_user,
            client_name_override: s.user.display_name,
            # 発行日=振込済にした当日、お振込日=同日(支払期限の計算値ではなく実際の振込日を出す)
            application_date: paid_on,
            due_date_override: paid_on
          ).call
          fname = "#{cat_label}_#{surname.presence || '通知'}_支払通知書_#{s.year}年_#{s.month}月分.pdf"
          attachments << { filename: fname, content_type: "application/pdf", body: File.binread(pdf_path) }
        end

        msg_id = GmailSender.new(user: current_user).send_mail(
          to: to_value,
          subject: params[:subject].to_s,
          body: params[:body].to_s,
          attachments: attachments,
          from_name: current_user.display_name
        )

        # 送信成功 → 対象 submission の paid_at を更新（既に paid_at 入っていても上書き）
        InvoiceSubmission.where(id: ids).update_all(paid_at: paid_on.beginning_of_day, updated_at: Time.current)

        render json: { ok: true, message_id: msg_id, sent_to: to_value, paid_at: paid_on.iso8601, count: ids.size, attachments: attachments.map { |a| a[:filename] } }
      rescue => e
        Rails.logger.error("[payment_notice_send] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def calc_total_for_submission(s)
        if s.kind == "expense"
          period = s.user.period_for(s.year, s.month)
          s.user.expenses.in_range(period).where(category: s.category, company_burden: true).sum(:amount).to_i
        else
          invoice_calc_total(s)
        end
      rescue
        0
      end

      # ラボップ宛メール本文の「請求金額の内訳」用に、添付ファイルと金額のリストを組み立てる。
      # labop_send の attachments 生成ロジックと同じ単位で1行ずつ並べる:
      #   - 同一 PO に複数申請 → 集約 PDF (filename ラベル)
      #   - 単一申請 → "{ユーザー} {年}年{月}月（{案件}）" ラベル
      #   - 立替金 (amount > 0) → カテゴリ単位で集約 PDF (filename ラベル)
      #   - 立替金 (amount < 0, 相殺) → 申請者ごとに別建て PDF (filename ラベル)
      def build_labop_breakdown_items(invoices, expenses, issued_pdfs = [])
        items = []

        # 保存済 統合 PDF (IssuedInvoicePdf): filename + total_amount をそのまま並べる。
        # AI 下書きの内訳は「メールに添付されるファイル」と一致するべきなので、
        # 統合(保存済)行を選択している場合はそれを優先して個別 invoice/expense の重複を避ける。
        # ラベル先頭には「{注文番号}: 」(invoice) または「立替金: 」(expense) を付ける。
        issued_pdfs.each do |ip|
          base = ip.filename.presence || "保存済PDF##{ip.id}"
          prefix = if ip.kind == "expense"
            "立替金: "
          elsif ip.purchase_order_no.present?
            "#{ip.purchase_order_no}: "
          else
            ""
          end
          base = base.sub(/\A立替金_/, "") if ip.kind == "expense"
          items << { label: "#{prefix}#{base}", amount: ip.total_amount.to_i }
        end

        invoices.to_a.group_by(&:received_purchase_order_id).each do |po_id, group|
          if po_id.present? && group.size >= 2
            primary = group.first
            effective_no = primary.purchase_order_no_override.presence || primary.received_purchase_order&.order_no
            surnames = group.map(&:user).map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
            cat_label = CATEGORY_LABELS[primary.category.to_s] || primary.category.to_s
            base = "#{cat_label}_#{surnames.presence || '集約'}_請求書_#{primary.year}年_#{primary.month}月分.pdf"
            label = effective_no.present? ? "#{effective_no}: #{base}" : base
            amount = group.sum { |s| s.total_override.to_i.nonzero? || invoice_calc_total(s) }
            items << { label: label, amount: amount }
          else
            group.each do |inv|
              cat_label = CATEGORY_LABELS[inv.category.to_s] || inv.category.to_s
              effective_no = inv.purchase_order_no_override.presence || inv.received_purchase_order&.order_no
              base = "#{inv.user.display_name} #{inv.year}年#{inv.month}月（#{cat_label}）"
              label = effective_no.present? ? "#{effective_no}: #{base}" : base
              amount = inv.total_override.to_i.nonzero? || invoice_calc_total(inv)
              items << { label: label, amount: amount }
            end
          end
        end

        expenses.to_a.group_by { |s| [ s.year, s.month, s.category ] }.each do |(y, m, c), subs|
          users = subs.map(&:user).uniq
          total = users.sum { |u|
            u.expenses.in_range(u.period_for(y, m)).where(category: c, company_burden: true).where("amount > 0").sum(:amount).to_i
          }
          next if total <= 0
          surnames = users.map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
          cat_label = CATEGORY_LABELS[c.to_s] || c.to_s
          base = "#{cat_label}_#{surnames.presence || '集約'}_立替金_#{y}年_#{m}月分.pdf"
          items << { label: "立替金: #{base}", amount: total }
        end

        expenses.to_a.each do |s|
          neg_total = s.user.expenses.in_range(s.user.period_for(s.year, s.month))
            .where(category: s.category, company_burden: true).where("amount < 0").sum(:amount).to_i
          next if neg_total >= 0
          surname = s.user.display_name.to_s.split(/[\s　]/).first.to_s
          cat_label = CATEGORY_LABELS[s.category.to_s] || s.category.to_s
          base = "#{cat_label}_#{surname}_立替金_相殺_#{s.year}年_#{s.month}月分.pdf"
          items << { label: "立替金: #{base}", amount: neg_total }
        end

        items
      end

      # カテゴリラベルを先頭に置く帳票ファイル名（カテゴリ_苗字_帳票名_…）
      def category_label_for(category)
        CATEGORY_LABELS[category.to_s] || category.to_s
      end
      def category_named_file(submission, body)
        surname = submission.user.display_name.to_s.split(/[\s　]/).first
        [ category_label_for(submission.category), surname, body ].map { |part| part.to_s.strip }.reject(&:blank?).join("_")
      end
      def invoice_filename(s)
        category_named_file(s, "請求書_#{s.year}年_#{s.month}月分_株式会社ラボップ.pdf")
      end
      def expense_pdf_filename(s)
        category_named_file(s, "立替金_#{s.year}年_#{s.month}月分_株式会社ラボップ.pdf")
      end
      def expense_xlsx_filename(s)
        category_named_file(s, "立替金_#{s.year}年_#{s.month}月分_株式会社ラボップ.xlsx")
      end
      def work_report_filename(s)
        category_named_file(s, "業務報告書_#{s.year}年_#{s.month}月分.xlsx")
      end
    end
  end
end
