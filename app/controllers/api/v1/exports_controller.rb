require "open3"

module Api
  module V1
    class ExportsController < BaseController
      CATEGORY_LABELS = {
        "wings" => "Wing",
        "living" => "リビング",
        "techleaders" => "テックリーダーズ",
        "resystems" => "REシステムズ"
      }.freeze

      def work_report
        year, month = parse_month
        cat = params[:category].presence
        path = WorkReportExporter.new(current_user, year: year, month: month, category: cat).call
        filename = with_name_prefix("#{CATEGORY_LABELS[cat] || 'Wing'}_業務報告書_#{year}年_#{month}月分.xlsx")
        return respond_save_local(:work_report, path, filename, cat, year, month) if save_local?
        send_file path,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          filename: filename, disposition: "attachment"
      end

      def expense
        year, month = parse_month
        cat = params[:category].presence
        viewer = viewing_user
        target_user, client_override, issuer_override, _submission = resolve_expense_target(viewer: viewer, year: year, month: month, category: cat)
        path = ExpenseExporter.new(target_user, year: year, month: month,
          application_date: parse_application_date, category: cat,
          client_name_override: client_override, issuer_user_override: issuer_override).call
        prefix = CATEGORY_LABELS[cat] ? "立替金_#{CATEGORY_LABELS[cat]}" : "立替金"
        filename = with_name_prefix("#{prefix}_#{year}年_#{month}月分.xlsx", user: target_user)
        return respond_save_local(:expense, path, filename, cat, year, month) if save_local?
        send_file path,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          filename: filename, disposition: "attachment"
      end

      def invoice
        year, month = parse_month
        cat = params[:category].presence
        # admin が as_user_id で他ユーザとして閲覧している時は、その user 視点の請求書を素で出す
        viewer = viewing_user
        target_user, client_override, issuer_override, submission = resolve_invoice_target(viewer: viewer, year: year, month: month, category: cat)
        # ラボップ宛 (issuer_override) のときは submission.application_date_override（川村が申請した日が入りがち）
        # を使わず、明示パラメータ or 発行者(西野)の設定 → 末日 を採用する
        application_date = if issuer_override
                             parse_application_date
        else
                             submission&.application_date_override || parse_application_date
        end
        # PO がリンクされていれば note 先頭に「注文番号: ORD-XXX」を自動付与
        po_no_for_note = submission&.received_purchase_order&.order_no
        po_line = po_no_for_note.present? ? "注文番号: #{po_no_for_note}" : nil
        composed_note = [ po_line, submission&.note ].compact.reject(&:blank?).join("\n").presence
        path = InvoicePdfRenderer.new(
          target_user,
          year: year, month: month, category: cat,
          application_date: application_date,
          client_name_override: client_override,
          issuer_user_override: issuer_override,
          total_override: submission&.total_override,
          item_label_override: submission&.item_label_override,
          note: composed_note,
          subject_override: submission&.subject_override,
          items_override: submission&.items_override
        ).call
        filename = with_name_prefix("請求書_#{year}年_#{month}月分.pdf", user: target_user)
        return respond_save_local(:invoice, path, filename, cat, year, month) if save_local?
        send_file path, type: "application/pdf", filename: filename, disposition: "attachment"
      end

      def purchase_order
        raise "発注権限がありません" unless current_user.can_issue_orders
        payload = params.permit(
          :order_date, :order_no, :subject, :tax_rate, :category,
          :delivery_deadline, :delivery_location, :payment_method, :remarks,
          recipient: [ :name, :postal_code, :address ],
          issuer: [ :company_name, :representative, :postal_code, :address ],
          items: [ :description, :qty, :unit, :unit_price, :amount ]
        ).to_h.deep_symbolize_keys
        path = PurchaseOrderPdfRenderer.new(current_user, payload).call
        order_no = payload[:order_no].presence || "ORD"
        filename = "発注書_#{order_no}.pdf"
        if save_local?
          year = payload[:order_date].to_s[0, 4].to_i
          year = Date.current.year if year.zero?
          return respond_save_local(:purchase_order, path, filename, payload[:category].to_s, year, nil)
        end
        send_file path, type: "application/pdf", filename: filename, disposition: "attachment"
      end

      def expense_pdf
        year, month = parse_month
        cat = params[:category].presence
        viewer = viewing_user
        target_user, client_override, issuer_override, _submission = resolve_expense_target(viewer: viewer, year: year, month: month, category: cat)
        path = ExpensePdfRenderer.new(target_user, year: year, month: month,
          application_date: parse_application_date, category: cat,
          client_name_override: client_override, issuer_user_override: issuer_override).call
        prefix = CATEGORY_LABELS[cat] ? "立替金_#{CATEGORY_LABELS[cat]}" : "立替金"
        filename = with_name_prefix("#{prefix}_#{year}年_#{month}月分.pdf", user: target_user)
        return respond_save_local(:expense, path, filename, cat, year, month) if save_local?
        send_file path, type: "application/pdf", filename: filename, disposition: "attachment"
      end

      # 集約版: 複数の InvoiceSubmission をマージして 1 PDF を返す（admin のみ）
      # POST /exports/merged_invoice.pdf  with invoice_submission_ids[]
      def merged_invoice
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        ids = Array(params[:invoice_submission_ids]).map(&:to_i).reject(&:zero?)
        subs = InvoiceSubmission.where(id: ids).where(kind: "invoice").approved.includes(:user, :received_purchase_order)
        return render(json: { error: "対象なし" }, status: :unprocessable_entity) if subs.empty?

        primary = subs.first
        others = subs.drop(1).map(&:user)
        po = primary.received_purchase_order
        po_line = po&.order_no.present? ? "注文番号: #{po.order_no}" : nil
        composed_note = [ po_line, primary.note ].compact.reject(&:blank?).join("\n").presence
        merged_items = subs.flat_map { |s| s.items_override.is_a?(Array) ? s.items_override : [] }
        merged_items = nil if merged_items.empty?

        path = InvoicePdfRenderer.new(
          primary.user,
          year: primary.year, month: primary.month, category: primary.category,
          client_name_override: I18n.t("companies.labop.name"),
          issuer_user_override: current_user,
          item_label_override: primary.item_label_override,
          subject_override: primary.subject_override,
          items_override: merged_items,
          note: composed_note,
          merged_users: others
        ).call

        surnames = subs.map(&:user).map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
        cat_label = CATEGORY_LABELS[primary.category.to_s] || primary.category.to_s
        filename = "#{surnames.presence || '集約'}_請求書_#{cat_label}_#{primary.year}年_#{primary.month}月分.pdf"
        send_file path, type: "application/pdf", filename: filename, disposition: params[:disposition].presence || "attachment"
      end

      # 集約版: 複数の expense submission の amount>0 expense を 1 PDF にマージ
      # POST /exports/merged_expense.pdf  with expense_submission_ids[]
      def merged_expense
        merged_expense_internal(format: :pdf)
      end

      def merged_expense_xlsx
        merged_expense_internal(format: :xlsx)
      end

      # macOS 限定: osascript で「フォルダを選択」ダイアログを開いて POSIX パスを返す
      # default_path を渡すとそのフォルダを初期表示
      def pick_local_dir
        # 本番(Linux) ではダイアログ自体不要・osascript も無いので 404 で塞ぐ
        return render(json: { error: "macOS only" }, status: :not_implemented) unless Rails.env.development?

        # AppleScript injection 防止: ダブルクォート / バックスラッシュ / 制御文字を含む path は拒否
        default_path = params[:default_path].to_s
        return render(json: { error: "invalid path" }, status: :unprocessable_entity) if default_path.match?(/["\\\x00-\x1f]/)

        # default_path が存在しない場合は親をたどって存在する先頭まで戻す
        while default_path.present? && !File.directory?(default_path)
          parent = File.dirname(default_path)
          break if parent == default_path
          default_path = parent
        end

        # Finder を前面化してからダイアログを出す（ブラウザ背面に隠れないように）
        applescript = if default_path.present? && File.directory?(default_path)
          <<~OSA
            tell application "Finder"
              activate
              set f to POSIX path of (choose folder with prompt "保存先フォルダを選択" default location (POSIX file "#{default_path}"))
            end tell
          OSA
        else
          <<~OSA
            tell application "Finder"
              activate
              set f to POSIX path of (choose folder with prompt "保存先フォルダを選択")
            end tell
          OSA
        end

        out, err, status = Open3.capture3("osascript", "-e", applescript)
        return render(json: { canceled: true }, status: :ok) unless status.success?
        render json: { path: out.strip }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 指定パス配下のサブディレクトリ一覧（ローカル運用前提・OS のフォルダ階層を返す）
      def list_local_dirs
        raw = params[:path].to_s
        # template placeholders を展開（{year} {month} {cat} {name}）
        cat_folder = LocalFileSaver::CATEGORY_FOLDER[params[:category].to_s] || "TAMA"
        path = LocalFileSaver.expand_template(
          raw,
          year: params[:year].presence&.to_i || Date.current.year,
          month: params[:month].presence&.to_i || Date.current.month,
          cat: cat_folder,
          user: current_user
        )
        path = File.expand_path(path)
        return render(json: { path: path, exists: false, entries: [] }) unless File.directory?(path)
        entries = Dir.children(path)
                     .reject { |child| child.start_with?(".") }
                     .select { |child| File.directory?(File.join(path, child)) }
                     .sort
        render json: { path: path, exists: true, entries: entries }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # 集約 expense (PDF or Excel) 共通処理
      def merged_expense_internal(format:)
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        ids = Array(params[:expense_submission_ids]).map(&:to_i).reject(&:zero?)
        subs = InvoiceSubmission.where(id: ids).where(kind: "expense").approved.includes(:user)
        return render(json: { error: "対象なし" }, status: :unprocessable_entity) if subs.empty?

        # 全部 (year, month, category) が同一前提（呼び出し側で同じ集約グループの ids のみ渡す）
        primary = subs.first
        users = subs.map(&:user).uniq
        others = users.drop(1)
        renderer_class = format == :xlsx ? ExpenseExporter : ExpensePdfRenderer
        path = renderer_class.new(
          users.first, year: primary.year, month: primary.month, category: primary.category,
          client_name_override: I18n.t("companies.labop.name"),
          issuer_user_override: current_user,
          merged_users: others, mode: :positive
        ).call
        surnames = users.map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
        cat_label = CATEGORY_LABELS[primary.category.to_s] || primary.category.to_s
        ext = format == :xlsx ? "xlsx" : "pdf"
        ctype = format == :xlsx ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/pdf"
        filename = "立替金_#{surnames.presence || '集約'}_#{cat_label}_#{primary.year}年_#{primary.month}月分.#{ext}"
        send_file path, type: ctype, filename: filename, disposition: params[:disposition].presence || "attachment"
      end

      def save_local?
        ActiveModel::Type::Boolean.new.cast(params[:save_local])
      end

      def respond_save_local(type, src, filename, category, year, month)
        dest = LocalFileSaver.save(type: type, src_path: src, filename: filename, category: category, year: year, month: month, user: current_user)
        render json: { saved_to: dest, filename: filename }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # display_name の苗字を先頭につける（"西野 鷹也" → "西野_..."）
      def with_name_prefix(filename, user: current_user)
        surname = user.display_name.to_s.split(/[\s　]/).first
        return filename if surname.blank?
        return filename if filename.start_with?("#{surname}_")
        "#{surname}_#{filename}"
      end

      # 承認済の InvoiceSubmission を指定して admin (西野) が DL する場合、
      # 請求元ユーザー (例: 川村) の請求書を「株式会社ラボップ」宛 / 西野発行で生成する。
      # それ以外のケースは viewer (= as_user_id 反映済み current_user 相当) の請求書を素で出す。
      # 戻り値: [target_user, client_name_override, issuer_user_override, submission]
      def resolve_invoice_target(viewer:, year:, month:, category:)
        submission_id = params[:invoice_submission_id]
        return [ viewer, nil, nil, nil ] if submission_id.blank?
        return [ viewer, nil, nil, nil ] unless current_user.admin?

        submission = InvoiceSubmission.find_by(id: submission_id)
        return [ viewer, nil, nil, nil ] unless submission&.approved?
        return [ viewer, nil, nil, nil ] unless submission.year == year && submission.month == month
        return [ viewer, nil, nil, nil ] if category.present? && submission.category != category

        [ submission.user, I18n.t("companies.labop.name"), current_user, submission ]
      end

      # 立替金 (expense) 用: 承認済 expense submission を指定された場合、
      # 申請者ユーザの立替金を「株式会社ラボップ」宛 / 西野発行で生成。
      def resolve_expense_target(viewer:, year:, month:, category:)
        submission_id = params[:invoice_submission_id]
        return [ viewer, nil, nil, nil ] if submission_id.blank?
        return [ viewer, nil, nil, nil ] unless current_user.admin?

        submission = InvoiceSubmission.find_by(id: submission_id)
        return [ viewer, nil, nil, nil ] unless submission&.approved?
        return [ viewer, nil, nil, nil ] unless submission.kind == "expense"
        return [ viewer, nil, nil, nil ] unless submission.year == year && submission.month == month
        return [ viewer, nil, nil, nil ] if category.present? && submission.category != category

        [ submission.user, I18n.t("companies.labop.name"), current_user, submission ]
      end
    end
  end
end
