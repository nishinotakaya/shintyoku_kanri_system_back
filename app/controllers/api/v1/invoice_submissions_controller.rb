module Api
  module V1
    class InvoiceSubmissionsController < BaseController
      include FreeeReportable
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
        when "draft"
          scope = scope.draft
        when "pending"
          scope = scope.pending
        else
          scope = scope.pending
        end
        scope = scope.where(kind: params[:kind]) if params[:kind].present? && InvoiceSubmission::KINDS.include?(params[:kind].to_s)
        # draft は submitted_at が nil なので作成日時でフォールバックして並べる
        records = scope.order(Arel.sql("COALESCE(submitted_at, created_at) DESC")).includes(:user, :reviewer)
        render json: records.map { |r| serialize(r) }
      end

      def create
        kind = params[:kind].to_s.presence || "invoice"
        kind = "invoice" unless InvoiceSubmission::KINDS.include?(kind)
        year = params[:year].to_i
        month = params[:month].to_i
        category = params[:category].to_s.presence || "wings"
        po_id = params[:received_purchase_order_id].presence
        # admin (西野) のみ target_user_id で他ユーザー宛申請を作成可能。それ以外は自分自身に限定。
        target_user =
          if current_user.admin? && params[:target_user_id].present?
            User.find(params[:target_user_id])
          else
            current_user
          end
        # 作成は「下書き(draft)」のみ。申請は別途 submit / submit_bulk で行う。
        # 同一ユーザー × 年月 × カテゴリ × kind × 発注書 は一意。既に存在すれば上書き(再作成)
        # 発注書が異なれば別レコードを作る → 1 月内で複数請求書発行に対応
        record = InvoiceSubmission.find_or_initialize_by(
          user: target_user, year: year, month: month, category: category, kind: kind,
          received_purchase_order_id: po_id
        )
        is_resubmit = record.persisted?
        # 手入力の明細（業務報告に依存しないシンプル作成）。あれば最優先で使い、合計も明細から算出。
        manual_items = normalize_items_override(params[:items_override])
        # 自動算出した税込合計を total_override に入れる (admin の一覧表示で「未設定」にならないように)
        auto_total = compute_total_tax_inc(target_user, year, month, category, kind)
        record.assign_attributes(
          note: params[:note].to_s.presence,
          total_override: manual_items.present? ? manual_total_tax_inc(manual_items, category) : auto_total,
          status: "draft",
          reviewer_id: nil,
          reviewed_at: nil,
          submitted_at: nil
        )
        # 手入力があった時だけ上書き（空での再申請で既存の明細/件名を消さない）
        record.items_override = manual_items if manual_items.present?
        record.subject_override = params[:subject_override].to_s.presence if params.key?(:subject_override)
        # 請求書単体で持てる項目: インボイス番号 / 申請日 / 支払期限
        record.registration_no_override = params[:registration_no_override].to_s.presence if params.key?(:registration_no_override)
        record.application_date_override = parse_date_param(params[:application_date_override]) if params.key?(:application_date_override)
        record.due_date_override = parse_date_param(params[:due_date_override]) if params.key?(:due_date_override)
        record.bank_info_override = params[:bank_info_override].to_s.presence if params.key?(:bank_info_override)
        record.save!

        render json: serialize(record).merge(resubmitted: is_resubmit)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 編集は admin または本人(owner)が可能。
      # ただしステータス変更(承認/却下)は admin のみ。内容(備考/金額/明細/日付/インボイス番号等)は本人も編集可。
      def update
        record = InvoiceSubmission.find(params[:id])
        is_owner = record.user_id == current_user.id
        unless current_user.admin? || is_owner
          return render(json: { error: "編集権限がありません" }, status: :forbidden)
        end
        attrs = {}

        if params.key?(:status)
          return render(json: { error: "承認権限がありません(ステータス変更は管理者のみ)" }, status: :forbidden) unless current_user.admin?
          new_status = params[:status].to_s
          return render(json: { error: "不正なステータス" }, status: :unprocessable_entity) unless InvoiceSubmission::STATUSES.include?(new_status)
          attrs[:status] = new_status
          attrs[:reviewer_id] = current_user.id
          attrs[:reviewed_at] = Time.current
        end
        # 備考は空欄での「クリア」を許可するため key? で判定（present? だと空文字が無視され消せない）
        attrs[:note] = params[:note].to_s.presence if params.key?(:note)
        # 却下/承認時の admin コメント (空文字で「クリア」を許可するため key? で判定)
        if params.key?(:review_comment)
          attrs[:review_comment] = params[:review_comment].to_s.presence
        end
        if params.key?(:received_purchase_order_id)
          attrs[:received_purchase_order_id] = params[:received_purchase_order_id].presence
        end
        if params.key?(:purchase_order_no_override)
          attrs[:purchase_order_no_override] = params[:purchase_order_no_override].to_s.presence
        end
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
        # 支払期限の上書き（空欄なら nil = 設定からの自動計算に戻す）
        if params.key?(:due_date_override)
          raw = params[:due_date_override].to_s
          attrs[:due_date_override] = raw.present? ? Date.iso8601(raw) : nil
        end
        # インボイス番号(登録番号)の請求書単体上書き（空欄なら nil = 設定の値に戻す）
        if params.key?(:registration_no_override)
          attrs[:registration_no_override] = params[:registration_no_override].to_s.presence
        end
        if params.key?(:bank_info_override)
          attrs[:bank_info_override] = params[:bank_info_override].to_s.presence
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

        # 振込済ステータスの取消 (paid_at を null にしたい / 振込日を更新したい用途)
        if params.key?(:paid_at)
          raw = params[:paid_at].to_s
          attrs[:paid_at] = raw.present? ? (Time.iso8601(raw) rescue Date.parse(raw).beginning_of_day) : nil
        end

        record.update!(attrs) if attrs.any?
        render json: serialize(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/invoice_submissions/:id/submit
      # 下書き(draft)を「申請」する。所有者本人 or admin が実行可能。
      def submit
        record = InvoiceSubmission.find(params[:id])
        return render(json: { error: "権限がありません" }, status: :forbidden) unless can_submit?(record)
        do_submit(record)
        render json: serialize(record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/invoice_submissions/submit_bulk  { ids: [..] }
      # 選択した下書きを一括申請。権限の無いものはスキップ。
      def submit_bulk
        ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
        done = []
        InvoiceSubmission.where(id: ids).each do |record|
          next unless can_submit?(record)
          do_submit(record)
          done << record.id
        end
        render json: { submitted_ids: done }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/invoice_submissions/:id/report_to_freee
      # 既存の申請を freee 売上として計上する。
      def report_to_freee
        record = InvoiceSubmission.find(params[:id])
        unless current_user.admin? || record.user_id == current_user.id
          return render(json: { error: "権限がありません" }, status: :forbidden)
        end
        return render(json: { error: "請求書 (kind=invoice) のみ計上可能" }, status: :unprocessable_entity) unless record.kind == "invoice"

        total = record.total_override.to_i
        return render(json: { error: "総額が 0 円のため計上不可" }, status: :unprocessable_entity) if total.zero?

        due = record.application_date_override.presence ||
              Date.new(record.year, record.month, -1)
        subject = record.subject_override.presence ||
                  "#{record.year}年#{record.month}月分 (#{CAT_LABELS[record.category] || record.category})"

        report_record_to_freee!(
          record: record,
          invoice_payload: {
            total_amount: total,
            due_date: due.to_s,
            subject: subject,
            category: record.category
          }
        )
      end

      # POST /api/v1/invoice_submissions/bulk
      # 申請者から複数(カテゴリ × kind)を一度に申請し、admin への通知を「1通のメール」に集約する。
      # params:
      #   year: int, month: int
      #   submissions: [ { category, kind, note?, received_purchase_order_id?, purchase_order_no_override? }, ... ]
      def bulk_create
        year = params[:year].to_i
        month = params[:month].to_i
        combos = Array(params[:submissions])
        return render(json: { error: "submissions が空です" }, status: :unprocessable_entity) if combos.empty?

        target_user = current_user
        auto_approve = current_user.admin? && target_user.id == current_user.id
        created_or_updated = []
        errors = []

        ActiveRecord::Base.transaction do
          combos.each do |c|
            kind = c[:kind].to_s.presence || "invoice"
            kind = "invoice" unless InvoiceSubmission::KINDS.include?(kind)
            category = c[:category].to_s.presence || "wings"
            po_id = c[:received_purchase_order_id].presence
            record = InvoiceSubmission.find_or_initialize_by(
              user: target_user, year: year, month: month, category: category, kind: kind,
              received_purchase_order_id: po_id
            )
            auto_total = compute_total_tax_inc(target_user, year, month, category, kind)
            record.assign_attributes(
              note: c[:note].to_s.presence,
              total_override: auto_total,
              status: auto_approve ? "approved" : "pending",
              reviewer_id: auto_approve ? current_user.id : nil,
              reviewed_at: auto_approve ? Time.current : nil,
              submitted_at: Time.current
            )
            record.save!
            created_or_updated << record
          end
        end

        # 通知は 1 通にまとめて送信（自己承認 admin は通知不要）
        notify_admin_bulk(created_or_updated) if !auto_approve && created_or_updated.any?

        render json: created_or_updated.map { |r| serialize(r) }
      rescue => e
        render json: { error: e.message, details: errors }, status: :unprocessable_entity
      end

      # 削除: admin or 自分の申請のみ
      def destroy
        record = InvoiceSubmission.find(params[:id])
        unless current_user.admin? || record.user_id == current_user.id
          return render(json: { error: "権限がありません" }, status: :forbidden)
        end
        record.destroy!
        head :no_content
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # "YYYY-MM-DD" / ISO8601 / 空 を Date|nil に。
      def parse_date_param(raw)
        s = raw.to_s.strip
        return nil if s.empty?
        (Time.iso8601(s) rescue Date.parse(s)) rescue nil
      end

      # 申請を実行できるか: 本人 or admin
      def can_submit?(record)
        current_user.admin? || record.user_id == current_user.id
      end

      # 下書き等を申請状態へ。admin が自分宛なら自動承認、それ以外は pending + 西野へ通知。
      def do_submit(record)
        auto_approve = current_user.admin? && record.user_id == current_user.id
        record.update!(
          status: auto_approve ? "approved" : "pending",
          reviewer_id: auto_approve ? current_user.id : nil,
          reviewed_at: auto_approve ? Time.current : nil,
          submitted_at: Time.current
        )
        notify_admin_on_create(record) unless auto_approve
      end

      KIND_LABELS = { "invoice" => "請求書", "expense" => "立替金", "work_report" => "業務報告書" }.freeze
      CAT_LABELS = { "wings" => "Tama", "living" => "リビング", "techleaders" => "テックリーダーズ", "resystems" => "REシステムズ", "video" => "動画編集" }.freeze

      # 申請レコードの「税込合計」を自動算出して total_override に入れる用ヘルパー。
      # - invoice: InvoicePdfRenderer.calculation[:total]  (税込)
      # - expense: ユーザーの該当期間 expense.amount 合計 (元から税込)
      # 手入力明細を正規化（[{label,qty,unit,unit_price,amount}]）。空行は除外。何も無ければ nil。
      def normalize_items_override(raw)
        return nil unless raw.is_a?(Array) && raw.any?
        items = raw.map do |it|
          h = it.respond_to?(:to_unsafe_h) ? it.to_unsafe_h : it.to_h
          qty = h["qty"].to_f
          unit_price = h["unit_price"].to_i
          amount = h["amount"].present? ? h["amount"].to_i : (qty * unit_price).round
          { "label" => h["label"].to_s, "qty" => qty, "unit" => h["unit"].to_s.presence || "式",
            "unit_price" => unit_price, "amount" => amount }
        end
        items.reject { |it| it["label"].blank? && it["amount"].zero? }.presence
      end

      # 手入力明細から税込合計を出す（税率はカテゴリ既定: wings/living=10% / resystems等=0%）。
      def manual_total_tax_inc(items, category)
        subtotal = items.sum { |it| it["amount"].to_i }
        tax_rate = InvoiceSetting.defaults_for(category)[:tax_rate].to_i
        (subtotal + (subtotal * tax_rate / 100.0).round).to_i
      end

      def compute_total_tax_inc(user, year, month, category, kind)
        if kind.to_s == "invoice"
          InvoicePdfRenderer.new(user, year: year, month: month, category: category).calculation[:total].to_i
        else
          period = user.period_for(year, month)
          user.expenses.billed_in(format("%04d-%02d", year, month), period).where(category: category).sum(:amount).to_i
        end
      rescue => e
        Rails.logger.warn("[InvoiceSubmissions] compute_total failed: #{e.class}: #{e.message}")
        nil
      end

      def notify_admin_on_create(record)
        kind_label = KIND_LABELS[record.kind] || record.kind
        cat_label = CAT_LABELS[record.category] || record.category
        approve_url = ENV.fetch("FRONTEND_APPROVE_URL", "https://react-frontend-beige.vercel.app/attendance")
        text = "📨 #{kind_label}の申請が届きました\n申請者: #{record.user&.display_name}\n対象: #{record.year}年#{record.month}月（#{cat_label}）\n\n👉 承認はこちら:\n#{approve_url}"
        LineNotifier.push(text)

        # 添付付きでも admin にメール送信 (admin 自身の OAuth トークンを使う)
        notify_admin_by_email(record, kind_label, cat_label, approve_url)
      rescue => e
        Rails.logger.warn("[InvoiceSubmissions] notify failed: #{e.class}: #{e.message}")
      end

      # 複数の申請をまとめて 1 通の通知メールで admin に送る (LINE は短く 1 行)。
      def notify_admin_bulk(records)
        return if records.empty?
        first = records.first
        applicant = first.user
        approve_url = ENV.fetch("FRONTEND_APPROVE_URL", "https://react-frontend-beige.vercel.app/attendance")
        admin = User.where("email = ? OR display_name LIKE ?", "takaya314boxing@gmail.com", "%西野%").first
        return unless admin&.google_access_token.present?

        # LINE: 集約 1 行で通知
        kind_summary = records.map { |r| "#{CAT_LABELS[r.category] || r.category}/#{KIND_LABELS[r.kind] || r.kind}" }.join(", ")
        LineNotifier.push("📨 一括申請が届きました\n申請者: #{applicant.display_name}\n対象: #{first.year}年#{first.month}月\n内訳: #{kind_summary}\n\n👉 承認: #{approve_url}") rescue nil

        # メール: 全申請を 1 通に集約。各 (category) ごとに PDF/Excel 添付。
        surname = applicant.display_name.to_s.split(/[\s　]/).first.to_s
        fmt = ->(n) { "¥#{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}" }
        attachments = []
        body_lines = []
        body_lines << "西野様"
        body_lines << ""
        body_lines << "#{applicant.display_name} さんから一括申請が届きました。"
        body_lines << ""
        body_lines << "対象: #{first.year}年#{first.month}月分"
        body_lines << ""
        body_lines << "【内訳】"

        grand_invoice = 0
        grand_expense = 0
        skipped_reasons = []
        records.group_by(&:category).each do |cat, recs|
          cat_label = CAT_LABELS[cat] || cat
          period = applicant.period_for(first.year, first.month)

          # 事前に金額/工数を計算して 0 のものは添付を作らない。請求書は申請の上書きを反映する。
          inv_sub = recs.find { |r| r.kind == "invoice" }
          inv_opts = invoice_render_opts(inv_sub)
          invoice_total = inv_sub ? (InvoicePdfRenderer.new(applicant, year: first.year, month: first.month, category: cat, **inv_opts).calculation[:total] rescue 0) : 0
          expense_total = recs.any? { |r| r.kind == "expense" } ? applicant.expenses.in_range(period).where(category: cat).sum(:amount).to_i : 0
          wr_hours      = applicant.work_reports.in_range(period).by_category(cat).sum(:hours).to_f
          kind_labels_for_cat = []

          if inv_sub
            if invoice_total > 0
              invoice_pdf = InvoicePdfRenderer.new(applicant, year: first.year, month: first.month, category: cat, **inv_opts).call
              attachments << { filename: "#{cat_label}_#{surname}_請求書_#{first.year}年_#{first.month}月分.pdf",
                               content_type: "application/pdf", body: File.binread(invoice_pdf) }
              kind_labels_for_cat << "請求書"
            else
              skipped_reasons << "#{cat_label} 請求書: 0円のため添付スキップ"
            end
          end
          if recs.any? { |r| r.kind == "expense" }
            if expense_total > 0
              exp_pdf = ExpensePdfRenderer.new(applicant, year: first.year, month: first.month, category: cat).call
              attachments << { filename: "#{cat_label}_#{surname}_立替金_#{first.year}年_#{first.month}月分.pdf",
                               content_type: "application/pdf", body: File.binread(exp_pdf) }
              exp_xlsx = ExpenseExporter.new(applicant, year: first.year, month: first.month, category: cat).call
              attachments << { filename: "#{cat_label}_#{surname}_立替金_#{first.year}年_#{first.month}月分.xlsx",
                               content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(exp_xlsx) }
              kind_labels_for_cat << "立替金"
            else
              skipped_reasons << "#{cat_label} 立替金: 0円のため添付スキップ"
            end
          end
          if wr_hours > 0
            wr = WorkReportExporter.new(applicant, year: first.year, month: first.month, category: cat).call
            attachments << { filename: "#{cat_label}_#{surname}_業務報告書_#{first.year}年_#{first.month}月分.xlsx",
                             content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(wr) }
          else
            skipped_reasons << "#{cat_label} 業務報告書: 稼働 0h のため添付スキップ"
          end

          body_lines << "  ▸ #{cat_label}（#{kind_labels_for_cat.join('+').presence || '— (全て0円)'}）"
          body_lines << "      請求書合計（税込）: #{fmt.call(invoice_total)}"  if invoice_total > 0
          body_lines << "      立替金合計:           #{fmt.call(expense_total)}" if expense_total > 0
          grand_invoice += invoice_total
          grand_expense += expense_total
        end

        body_lines << ""
        body_lines << "【合計】"
        body_lines << "  請求書 計（税込）: #{fmt.call(grand_invoice)}"
        body_lines << "  立替金 計:           #{fmt.call(grand_expense)}"
        body_lines << "  総額:                 #{fmt.call(grand_invoice + grand_expense)}"
        body_lines << ""
        body_lines << "添付: #{attachments.size} 件"
        if skipped_reasons.any?
          body_lines << ""
          body_lines << "【スキップ】"
          skipped_reasons.each { |r| body_lines << "  ・#{r}" }
        end
        body_lines << ""
        body_lines << "👉 承認はこちら: #{approve_url}"

        GmailSender.new(user: admin).send_mail(
          to: admin.email,
          subject: "📨 [一括申請] #{applicant.display_name} #{first.year}年#{first.month}月分 (#{records.size}件)",
          body: body_lines.join("\n"),
          attachments: attachments,
          from_name: "勤怠アプリ通知"
        )
      rescue => e
        Rails.logger.warn("[InvoiceSubmissions] bulk mail notify failed: #{e.class}: #{e.message}")
      end

      # 請求書申請(submission)の上書き項目を InvoicePdfRenderer の引数に変換する。
      # 通知メールの金額計算・PDF生成で申請の確定内容(total_override/items_override 等)を反映するため。
      def invoice_render_opts(submission)
        return {} unless submission&.kind == "invoice"
        {
          total_override: submission.total_override,
          items_override: submission.items_override,
          subject_override: submission.subject_override,
          item_label_override: submission.item_label_override,
          registration_no_override: submission.registration_no_override,
          due_date_override: submission.due_date_override,
          bank_info_override: submission.bank_info_override
        }
      end

      def notify_admin_by_email(record, kind_label, cat_label, approve_url)
        admin = User.where("email = ? OR display_name LIKE ?", "takaya314boxing@gmail.com", "%西野%").first
        return unless admin&.google_access_token.present?

        applicant = record.user
        surname = applicant.display_name.to_s.split(/[\s　]/).first.to_s
        attachments = []
        skipped = []
        period = applicant.period_for(record.year, record.month)

        # 事前に金額/工数を計算して 0 のものは添付を作らない。
        # 請求書の金額・明細は申請(record)の上書き(total_override/items_override)を反映する。
        # これが無いと動画編集など work_reports に時給が無い請求書が 0 円扱いになり、添付もスキップされる。
        inv_opts = invoice_render_opts(record.kind == "invoice" ? record : nil)
        invoice_total = InvoicePdfRenderer.new(applicant, year: record.year, month: record.month, category: record.category, **inv_opts).calculation[:total] rescue 0
        expense_total = applicant.expenses.in_range(period).where(category: record.category).sum(:amount).to_i
        wr_hours      = applicant.work_reports.in_range(period).by_category(record.category).sum(:hours).to_f

        if invoice_total > 0
          invoice_pdf = InvoicePdfRenderer.new(applicant, year: record.year, month: record.month, category: record.category, **inv_opts).call
          attachments << { filename: "#{cat_label}_#{surname}_請求書_#{record.year}年_#{record.month}月分.pdf",
                           content_type: "application/pdf", body: File.binread(invoice_pdf) }
        else
          skipped << "請求書: 0円のため添付スキップ"
        end

        if expense_total > 0
          exp_pdf = ExpensePdfRenderer.new(applicant, year: record.year, month: record.month, category: record.category).call
          attachments << { filename: "#{cat_label}_#{surname}_立替金_#{record.year}年_#{record.month}月分.pdf",
                           content_type: "application/pdf", body: File.binread(exp_pdf) }
          exp_xlsx = ExpenseExporter.new(applicant, year: record.year, month: record.month, category: record.category).call
          attachments << { filename: "#{cat_label}_#{surname}_立替金_#{record.year}年_#{record.month}月分.xlsx",
                           content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(exp_xlsx) }
        else
          skipped << "立替金: 0円のため添付スキップ"
        end

        if wr_hours > 0
          wr = WorkReportExporter.new(applicant, year: record.year, month: record.month, category: record.category).call
          attachments << { filename: "#{cat_label}_#{surname}_業務報告書_#{record.year}年_#{record.month}月分.xlsx",
                           content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", body: File.binread(wr) }
        else
          skipped << "業務報告書: 稼働 0h のため添付スキップ"
        end

        grand_total = invoice_total + expense_total
        fmt = ->(n) { "¥#{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}" }
        body = <<~BODY
          西野様

          #{applicant.display_name} さんから #{kind_label} の申請が届きました。

          対象: #{record.year}年#{record.month}月（#{cat_label}）
          ・請求書合計（税込）: #{fmt.call(invoice_total)}
          ・立替金合計        : #{fmt.call(expense_total)}
          ・総額              : #{fmt.call(grand_total)}

          添付ファイル（#{attachments.size} 件）:
          #{attachments.map { |a| "  ・#{a[:filename]}" }.join("\n").presence || "  （なし）"}
          #{skipped.any? ? "\n【スキップ】\n#{skipped.map { |s| "  ・#{s}" }.join("\n")}" : ""}
          👉 承認はこちら: #{approve_url}
        BODY

        GmailSender.new(user: admin).send_mail(
          to: admin.email,
          subject: "📨 [#{kind_label}申請] #{applicant.display_name} #{record.year}年#{record.month}月分 #{cat_label}",
          body: body,
          attachments: attachments,
          from_name: "勤怠アプリ通知"
        )
      rescue => e
        Rails.logger.warn("[InvoiceSubmissions] mail notify failed: #{e.class}: #{e.message}")
      end

      def serialize(record)
        defaults = approved_defaults_for(record)
        # 申請者の請求書設定は 1 回だけ引く（default_* 5項目で毎回引くと一覧APIが N×5 クエリになる）
        applicant_setting = record.user&.invoice_setting_for(record.category)
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
          review_comment: record.review_comment,
          total_override: record.total_override,
          item_label_override: record.item_label_override,
          subject_override: record.subject_override,
          application_date_override: record.application_date_override&.iso8601,
          due_date_override: record.due_date_override&.iso8601,
          registration_no_override: record.registration_no_override,
          default_registration_no: applicant_setting&.registration_no,
          bank_info_override: record.bank_info_override,
          default_bank_info: applicant_setting&.bank_info,
          default_address: applicant_setting&.address,
          default_tel: applicant_setting&.tel,
          default_postal_code: applicant_setting&.postal_code,
          default_due_date: defaults[:due_date],
          items_override: record.items_override,
          default_total: defaults[:total],
          default_item_label: defaults[:item_label],
          default_subject: defaults[:subject],
          default_items: defaults[:items],
          default_application_date: defaults[:application_date],
          received_purchase_order_id: record.received_purchase_order_id,
          received_purchase_order_no: record.received_purchase_order&.order_no,
          received_purchase_order_subject: record.received_purchase_order&.subject,
          purchase_order_no_override: record.purchase_order_no_override,
          effective_purchase_order_no: record.purchase_order_no_override.presence || record.received_purchase_order&.order_no,
          paid_at: record.paid_at&.iso8601,
          freee_deal_id: record.freee_deal_id,
          freee_reported_at: record.freee_reported_at&.iso8601
        }
      end

      # approved の時のみ、ラボップモーダル初期表示用に
      # ラボップ宛 PDF と同じ「{氏名} 開発業務 1行 (qty=時間 / 単価=3,750)」の明細を返す
      def approved_defaults_for(record)
        return {} unless record.approved?
        if record.kind == "expense"
          # 立替金は対象月の expense.amount 合計（会社負担=true、amount>0 のみ）を default_total として返す
          period = record.user.period_for(record.year, record.month)
          total = record.user.expenses.in_range(period).where(category: record.category, company_burden: true).where("amount > 0").sum(:amount).to_i
          return { total: total }
        end
        return {} unless record.kind == "invoice"
        # issuer_user_override に reviewer (=admin) を渡すと labop_mode? が true になり、
        # 1 行明細の自動生成 + 内税 10% 逆算が走る → PDF と同じ初期値になる
        calc = InvoicePdfRenderer.new(
          record.user,
          year: record.year, month: record.month, category: record.category,
          issuer_user_override: record.reviewer || record.user
        ).calculation
        full_name = record.user.display_name.to_s.strip
        item_label = full_name.empty? ? "開発業務" : "#{full_name} 開発業務"
        {
          total: calc[:total],
          item_label: item_label,
          subject: record.user.invoice_setting_for(record.category || "wings").subject.to_s,
          items: calc[:items],
          application_date: calc[:application_date]&.iso8601,
          due_date: calc[:due_date]&.iso8601
        }
      rescue
        {}
      end
    end
  end
end
