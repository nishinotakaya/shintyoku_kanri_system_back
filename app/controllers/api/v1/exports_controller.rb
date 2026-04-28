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
        path = ExpenseExporter.new(current_user, year: year, month: month, application_date: parse_application_date, category: cat).call
        prefix = CATEGORY_LABELS[cat] ? "立替金_#{CATEGORY_LABELS[cat]}" : "立替金"
        filename = with_name_prefix("#{prefix}_#{year}年_#{month}月分.xlsx")
        return respond_save_local(:expense, path, filename, cat, year, month) if save_local?
        send_file path,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          filename: filename, disposition: "attachment"
      end

      def invoice
        year, month = parse_month
        cat = params[:category].presence
        target_user, override = resolve_invoice_target(year: year, month: month, category: cat)
        path = InvoicePdfRenderer.new(
          target_user,
          year: year, month: month, category: cat,
          application_date: parse_application_date,
          client_name_override: override
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
        path = ExpensePdfRenderer.new(current_user, year: year, month: month, application_date: parse_application_date, category: cat).call
        prefix = CATEGORY_LABELS[cat] ? "立替金_#{CATEGORY_LABELS[cat]}" : "立替金"
        filename = with_name_prefix("#{prefix}_#{year}年_#{month}月分.pdf")
        return respond_save_local(:expense, path, filename, cat, year, month) if save_local?
        send_file path, type: "application/pdf", filename: filename, disposition: "attachment"
      end

      # macOS 限定: osascript で「フォルダを選択」ダイアログを開いて POSIX パスを返す
      # default_path を渡すとそのフォルダを初期表示
      def pick_local_dir
        default_path = params[:default_path].to_s
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
      # 請求元ユーザー (例: 川村) の請求書を「株式会社ラボップ」宛で生成する。
      # それ以外のケースは現行通り current_user の請求書。
      def resolve_invoice_target(year:, month:, category:)
        submission_id = params[:invoice_submission_id]
        return [ current_user, nil ] if submission_id.blank?
        return [ current_user, nil ] unless current_user.admin?

        submission = InvoiceSubmission.find_by(id: submission_id)
        return [ current_user, nil ] unless submission&.approved?
        return [ current_user, nil ] unless submission.year == year && submission.month == month
        return [ current_user, nil ] if category.present? && submission.category != category

        [ submission.user, "株式会社ラボップ" ]
      end

      def parse_application_date
        Date.iso8601(params[:application_date]) if params[:application_date].present?
      end
    end
  end
end
