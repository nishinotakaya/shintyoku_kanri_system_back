require "open3"

module Api
  module V1
    class ExportsController < BaseController
      CATEGORY_LABELS = {
        "wings" => "Wings",
        "living" => "リビング",
        "techleaders" => "テックリーダーズ",
        "resystems" => "REシステムズ",
        "video" => "動画編集"
      }.freeze

      def work_report
        year, month = parse_month
        cat = params[:category].presence
        target_user = viewing_user  # admin が as_user_id を渡したらそのユーザーで生成
        path = WorkReportExporter.new(target_user, year: year, month: month, category: cat).call
        filename = category_prefixed("業務報告書_#{year}年_#{month}月分.xlsx", cat, user: target_user, default_label: "Wings")
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
        # 宛先デフォルト: target_user が admin = ラボップ、非admin = admin (西野) 宛
        # admin が submission_id 指定で他者の立替金をラボップ宛で出すケースは resolve_expense_target で既に決定済み
        client_override ||= target_user.invoice_recipient_name
        issuer_override ||= current_user
        date_submission = params[:invoice_submission_id].present? ? InvoiceSubmission.find_by(id: params[:invoice_submission_id]) : _submission
        date_submission ||= InvoiceSubmission.find_by(user_id: target_user.id, year: year, month: month, category: cat, kind: "expense")
        path = ExpenseExporter.new(target_user, year: year, month: month,
          application_date: parse_application_date || date_submission&.application_date_override, category: cat,
          client_name_override: client_override, issuer_user_override: issuer_override).call
        filename = category_prefixed("立替金_#{year}年_#{month}月分.xlsx", cat, user: target_user)
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
        # 申請日: 明示パラメータ > invoice_submission_id の申請の override > resolve した submission の override
        # ※ self/labop どちらの表示でも、編集UIで入れた申請日を PDF 左上へ反映する。
        date_submission = params[:invoice_submission_id].present? ? InvoiceSubmission.find_by(id: params[:invoice_submission_id]) : submission
        date_submission ||= InvoiceSubmission.find_by(user_id: target_user.id, year: year, month: month, category: cat, kind: "invoice")
        # 申請者ベース(self=invoice_submission_id 無し)でも、対象申請の上書き(金額/明細/支払期限/件名/備考)を反映する。
        # これが無いと resystems のように work_reports に時給データが無い請求書は合計 0 になってしまう。
        submission ||= date_submission
        application_date = parse_application_date || date_submission&.application_date_override || submission&.application_date_override
        # 注文番号: 上書き > PO リンク の優先順で「注文番号: XXX」を備考に自動付与
        po_no_for_note = submission&.purchase_order_no_override.presence || submission&.received_purchase_order&.order_no
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
          items_override: submission&.items_override,
          due_date_override: submission&.due_date_override,
          registration_no_override: submission&.registration_no_override,
          bank_info_override: submission&.bank_info_override
        ).call
        filename = category_prefixed("請求書_#{year}年_#{month}月分.pdf", cat, user: target_user)
        return respond_save_local(:invoice, path, filename, cat, year, month) if save_local?
        # 編集後の再プレビューで古いPDFがキャッシュ表示されないよう no-store
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        send_file path, type: "application/pdf", filename: filename, disposition: "attachment"
      end

      def purchase_order
        # PDF レンダリング自体は payload を PDF 化するだけのため誰でも実行可。
        # 川村が自分宛の発注書を再 DL するケースを許容する。新規発行のオペレーションは UI 側で can_issue_orders で制御する。
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
        # 宛先デフォルト: target_user が admin = ラボップ、非admin = admin (西野) 宛
        # admin が submission_id 指定で他者の立替金をラボップ宛で出すケースは resolve_expense_target で既に決定済み
        client_override ||= target_user.invoice_recipient_name
        issuer_override ||= current_user
        date_submission = params[:invoice_submission_id].present? ? InvoiceSubmission.find_by(id: params[:invoice_submission_id]) : _submission
        date_submission ||= InvoiceSubmission.find_by(user_id: target_user.id, year: year, month: month, category: cat, kind: "expense")
        path = ExpensePdfRenderer.new(target_user, year: year, month: month,
          application_date: parse_application_date || date_submission&.application_date_override, category: cat,
          client_name_override: client_override, issuer_user_override: issuer_override).call
        filename = category_prefixed("立替金_#{year}年_#{month}月分.pdf", cat, user: target_user)
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

        # primary user は admin (西野) を優先
        users_raw = subs.map(&:user).uniq
        users_sorted = users_raw.partition(&:admin?).flatten
        primary_user = users_sorted.first
        primary = subs.find { |s| s.user_id == primary_user.id } || subs.first
        others = users_sorted.drop(1)
        po = primary.received_purchase_order
        # 統合PDFの編集モーダルで注文番号を手入力/上書きした場合は、その値を最優先で採用する。
        # これが無いと再生成時に元申請由来の値で毎回上書きされ、手入力した注文番号が消える。
        # 手入力が空のときのみ、従来どおり元申請/受注書から導出する（既存挙動を維持）。
        effective_no = params[:purchase_order_no].to_s.strip.presence ||
                       primary.purchase_order_no_override.presence || po&.order_no
        # PDF 備考に「注文番号 / 件名 / 期限」を出す。order_no で受領注文書を引けたら、その件名・期間も併記する。
        composed_note = [ *purchase_order_note_lines(effective_no), primary.note ]
                          .compact.reject(&:blank?).join("\n").presence

        # 結合は「再計算しない」。各申請の請求書の確定額をそのまま使い、
        # 各人の明細は items_override があればその行、無ければ確定額(税抜)を1行に集約する。
        # 合計は merged_items（各申請の確定行）の合算から算出 = フロントの自動計算と一致。
        # （total_override が空の申請でも items から拾えるので漏れない）
        ordered_subs = MergedInvoiceItems.order(subs)
        # 統合PDFの編集明細(items_override パラメータ)が来たら、それを使う。
        # = 元申請(invoice_submissions)を一切書き換えずに統合PDFだけ更新する。
        edited_items = MergedInvoiceItems.normalize(params[:items_override])
        merged_items = edited_items || MergedInvoiceItems.build(ordered_subs)

        # 申請日: 統合PDFの編集モーダルで指定した application_date を最優先。
        # 無ければ、いずれかの申請の application_date_override を採用（従来挙動）。
        merged_application_date = parse_application_date || subs.map(&:application_date_override).compact.first

        renderer = InvoicePdfRenderer.new(
          primary_user,
          year: primary.year, month: primary.month, category: primary.category,
          application_date: merged_application_date,
          client_name_override: I18n.t("companies.labop.name"),
          issuer_user_override: current_user,
          item_label_override: primary.item_label_override,
          subject_override: primary.subject_override,
          items_override: merged_items,
          total_override: nil,
          note: composed_note,
          bank_info_override: primary.bank_info_override
        )
        path = renderer.call

        # 苗字順は admin (西野) 先頭に
        surnames = users_sorted.map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
        cat_label = CATEGORY_LABELS[primary.category.to_s] || primary.category.to_s
        filename = "#{cat_label}_#{surnames.presence || '集約'}_請求書_#{primary.year}年_#{primary.month}月分.pdf"

        # save=1 で IssuedInvoicePdf に永続化（replace_issued_id で上書き可）
        if params[:save].present?
          calc = renderer.calculation
          attrs = {
            user: current_user, kind: "invoice", file_format: "pdf",
            year: primary.year, month: primary.month, category: primary.category,
            purchase_order_no: effective_no,
            source_submission_ids: subs.map(&:id),
            merged: subs.size > 1,
            total_amount: calc[:total],
            filename: filename,
            file_data: File.binread(path),
            note: composed_note,
            items_override: merged_items,
            application_date: merged_application_date,
            generated_at: Time.current
          }
          upsert_issued_pdf!(attrs, params[:replace_issued_id], subs.map(&:id))
        end

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

      # 結合用: 1申請ぶんの「確定額そのまま」の明細行を返す（再計算しない）。
      # items_override があればその行（氏名 prefix 付き）、無ければ確定額(税抜)を1行に集約。
      def confirmed_items_for(submission)
        name = submission.user.display_name.to_s.strip
        prefix = name.empty? ? "" : "#{name} "
        if submission.items_override.present?
          return submission.items_override.map do |it|
            h = it.respond_to?(:to_h) ? it.to_h : it
            label = (h["label"] || h[:label]).to_s
            label = "#{prefix}#{label}" unless prefix.empty? || label.start_with?(prefix)
            { label: label, qty: (h["qty"] || h[:qty]).to_f, unit: ((h["unit"] || h[:unit]).to_s.presence || "式"),
              unit_price: (h["unit_price"] || h[:unit_price]).to_i, amount: (h["amount"] || h[:amount]).to_i }
          end
        end
        tax_rate = InvoiceSetting.defaults_for(submission.category)[:tax_rate].to_i
        subtotal = submission.total_override.to_i
        subtotal = (subtotal / (1.0 + tax_rate / 100.0)).round if tax_rate > 0
        label = "#{prefix}#{submission.subject_override.presence || submission.item_label_override.presence || submission.user.invoice_setting_for(submission.category).item_label}"
        [ { label: label, qty: 1, unit: "式", unit_price: subtotal, amount: subtotal } ]
      end

      # 注文番号から PDF 備考用の行を組み立てる。
      # order_no で受領注文書(received_purchase_orders)を引けたら、件名・期限も併記する。
      def purchase_order_note_lines(order_no)
        return [] if order_no.blank?
        lines = [ "注文番号: #{order_no}" ]
        po = ReceivedPurchaseOrder.where(order_no: order_no).order(period_end: :desc).first
        return lines unless po
        lines << "件名: #{po.subject}" if po.subject.present?
        deadline = po.period_end || po.period_start
        if po.period_start.present? && po.period_end.present?
          lines << "期限: #{po.period_start}〜#{po.period_end}"
        elsif deadline.present?
          lines << "期限: #{deadline}"
        end
        lines
      end

      # 統合 PDF/Excel の永続化共通ロジック:
      # 1. replace_issued_id 指定 → そのレコードを update（編集後の上書き保存）
      # 2. 同じ kind/file_format/year/month/category/source_submission_ids が既存 → そちらを update（重複防止）
      # 3. それ以外 → create
      def upsert_issued_pdf!(attrs, replace_id, src_ids)
        if replace_id.present?
          existing = IssuedInvoicePdf.find_by(id: replace_id)
          return overwrite_issued_pdf!(existing, attrs) if existing
        end
        # 同じ kind/file_format/year/month/category 内で source_submission_ids が一致するレコードを探す
        scope = IssuedInvoicePdf.where(
          kind: attrs[:kind], file_format: attrs[:file_format],
          year: attrs[:year], month: attrs[:month], category: attrs[:category]
        )
        sorted = src_ids.sort
        dup = scope.find { |x| Array(x.source_submission_ids).sort == sorted }
        return overwrite_issued_pdf!(dup, attrs) if dup
        IssuedInvoicePdf.create!(attrs)
      end

      # 既存の統合 PDF を上書きする前に、必ず旧版を退避してから update する。
      # これで誤った再生成でも [[revert]] で戻せる（Fly スナップショット復旧が不要になる）。
      def overwrite_issued_pdf!(record, attrs)
        IssuedInvoicePdf.transaction do
          IssuedInvoicePdfVersion.archive!(record, reason: "overwrite_by_regenerate")
          record.update!(attrs)
        end
        record
      end

      # 集約 expense (PDF or Excel) 共通処理
      def merged_expense_internal(format:)
        return render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
        ids = Array(params[:expense_submission_ids]).map(&:to_i).reject(&:zero?)
        subs = InvoiceSubmission.where(id: ids).where(kind: "expense").approved.includes(:user)
        return render(json: { error: "対象なし" }, status: :unprocessable_entity) if subs.empty?

        # primary user は admin (西野) を優先 → ファイル名・PDF 先頭が西野ベースになる
        users_raw = subs.map(&:user).uniq
        users = users_raw.partition(&:admin?).flatten
        primary_user = users.first
        primary = subs.find { |s| s.user_id == primary_user.id } || subs.first
        others = users.drop(1)
        renderer_class = format == :xlsx ? ExpenseExporter : ExpensePdfRenderer
        merged_application_date = subs.map(&:application_date_override).compact.first
        path = renderer_class.new(
          primary_user, year: primary.year, month: primary.month, category: primary.category,
          application_date: merged_application_date,
          client_name_override: I18n.t("companies.labop.name"),
          issuer_user_override: current_user,
          merged_users: others, mode: :positive
        ).call
        surnames = users.map { |u| u.display_name.to_s.split(/[\s　]/).first }.compact.reject(&:empty?).uniq.join("_")
        cat_label = CATEGORY_LABELS[primary.category.to_s] || primary.category.to_s
        ext = format == :xlsx ? "xlsx" : "pdf"
        ctype = format == :xlsx ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/pdf"
        filename = "#{cat_label}_#{surnames.presence || '集約'}_立替金_#{primary.year}年_#{primary.month}月分.#{ext}"

        # save=1 で IssuedInvoicePdf に永続化（合計金額も全ユーザー集約値）
        # replace_id が来たら既存レコードを上書き（編集 → 再生成 用途）
        if params[:save].present?
          combined_total = users.sum { |u|
            scope = u.expenses.billed_in(format("%04d-%02d", primary.year, primary.month), u.period_for(primary.year, primary.month))
              .where(category: primary.category, company_burden: true).where("amount > 0")
            scope = scope.where(excel_excluded: false) if format == :xlsx
            scope.sum(:amount).to_i
          }
          attrs = {
            user: current_user, kind: "expense", file_format: format.to_s,
            year: primary.year, month: primary.month, category: primary.category,
            source_submission_ids: subs.map(&:id),
            merged: subs.size > 1,
            total_amount: combined_total,
            filename: filename,
            file_data: File.binread(path),
            generated_at: Time.current
          }
          upsert_issued_pdf!(attrs, params[:replace_issued_id], subs.map(&:id))
        end

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

      # 帳票ファイル名: カテゴリラベル_苗字_<本体> （カテゴリを先頭に置く）
      # 例: "リビング_西野_業務報告書_2026年_6月分.xlsx"
      # default_label: カテゴリ未指定時に使うラベル（業務報告書は "Wings" を既定にする）
      def category_prefixed(body, category, user: current_user, default_label: nil)
        label = CATEGORY_LABELS[category.to_s] || default_label
        surname = user.display_name.to_s.split(/[\s　]/).first
        [ label, surname, body ].map { |part| part.to_s.strip }.reject(&:blank?).join("_")
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

        # admin が自分自身の請求書を見る場合はラボップ固定にせず、カテゴリ設定の宛先
        # (resystems=株式会社ReReシステムズ 等) を使う。submission は override 反映のため返す。
        return [ submission.user, nil, nil, submission ] if submission.user_id == current_user.id

        # admin が部下 (川村等) の請求書を「株式会社ラボップ」宛・西野発行で生成するケース
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
