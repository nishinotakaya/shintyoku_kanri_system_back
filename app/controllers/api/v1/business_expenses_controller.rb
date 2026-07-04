module Api
  module V1
    # 確定申告用の事業経費 (レシート撮影→AI読取→勘定科目分類)。
    # Phase 1 は西野(admin)専用。立替金(expenses)とは完全別管理。
    class BusinessExpensesController < BaseController
      before_action :require_admin
      before_action :set_record, only: [ :update, :destroy, :receipt ]

      # GET /api/v1/business_expenses?month=YYYY-MM&account_category=
      def index
        scope = current_user.business_expenses.order(expense_date: :desc, id: :desc)
        scope = scope.in_month(params[:month])
        scope = scope.where(account_category: params[:account_category]) if params[:account_category].present?
        records = scope.to_a
        render json: { expenses: records.map { |r| serialize(r) }, summary: summarize(records) }
      end

      # POST /api/v1/business_expenses  (multipart: file=レシート画像)
      # 画像をAIで読み取り、要確認(needs_review)状態で保存して返す。
      def create
        file = params[:file]
        return render(json: { error: "レシート画像を添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        bytes = file.read
        content_type = file.respond_to?(:content_type) ? file.content_type : "image/jpeg"
        extracted = ReceiptExtractor.call(bytes, content_type)
        return render(json: { error: extracted[:error] }, status: :unprocessable_entity) if extracted[:error]

        record = current_user.business_expenses.create!(
          expense_date: extracted[:expense_date] || Date.current,
          store_name: extracted[:store_name],
          amount: extracted[:amount],
          tax_rate: extracted[:tax_rate],
          account_category: extracted[:account_category],
          memo: extracted[:memo],
          status: "needs_review",
          receipt_data: bytes,
          content_type: content_type,
          ai_extracted_at: Time.current,
          ai_confidence: extracted[:confidence],
          ai_raw: extracted[:raw].to_json
        )
        render json: serialize(record), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/business_expenses/:id
      def update
        attrs = params.permit(:expense_date, :store_name, :amount, :tax_rate, :account_category, :memo, :business_ratio, :status)
        @record.update!(attrs.to_h.compact_blank.merge(params[:memo] ? { memo: params[:memo].to_s } : {}))
        render json: serialize(@record)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def destroy
        @record.destroy!
        head :no_content
      end

      # GET /api/v1/business_expenses/:id/receipt  レシート画像を返す
      def receipt
        return head :not_found if @record.receipt_data.blank?
        send_data @record.receipt_data, type: @record.content_type.presence || "image/jpeg", disposition: "inline"
      end

      # POST /api/v1/business_expenses/import_csv  (multipart: file=銀行/カード明細CSV)
      # 解析→AI仕訳して「プレビュー」を返す（この時点では保存しない）。
      def import_csv
        file = params[:file]
        return render(json: { error: "CSVファイルを添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        parsed = BankCsvParser.call(file.read)
        return render(json: { error: parsed[:error] }, status: :unprocessable_entity) if parsed[:error]

        categorized = TransactionCategorizer.call(parsed[:rows])
        existing_hashes = current_user.business_expenses.where(import_hash: categorized.map { |r| r[:import_hash] }).pluck(:import_hash).to_set
        rows = categorized.map { |r| r.merge(duplicate: existing_hashes.include?(r[:import_hash])) }
        render json: { rows: rows, count: rows.size, duplicate_count: rows.count { |r| r[:duplicate] } }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/business_expenses/import_commit  { rows: [{date, description, amount, account_category, memo, import_hash}] }
      # プレビューで選択された行を経費として一括登録（重複ハッシュはスキップ）。
      def import_commit
        rows = Array(params[:rows])
        return render(json: { error: "取込対象がありません" }, status: :unprocessable_entity) if rows.empty?

        imported = 0
        skipped = 0
        rows.each do |raw|
          row = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
          hash = row["import_hash"].to_s
          if hash.present? && current_user.business_expenses.exists?(import_hash: hash)
            skipped += 1
            next
          end
          category = row["account_category"].to_s.presence
          category = nil unless BusinessExpense::ACCOUNT_CATEGORIES.include?(category)
          current_user.business_expenses.create!(
            expense_date: (Date.iso8601(row["date"].to_s) rescue Date.current),
            store_name: row["description"].to_s.presence,
            amount: row["amount"].to_i,
            tax_rate: 10,
            account_category: category,
            memo: row["memo"].to_s.presence,
            status: "confirmed",
            source: "csv",
            import_hash: hash.presence
          )
          imported += 1
        end
        render json: { imported: imported, skipped: skipped }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/business_expenses/import_freee  { start_date?, end_date? }
      # freee に登録済みの経費(deal)を取得し、勘定科目を割り当てて business_expenses に保存。
      def import_freee
        conn = current_user.freee_connection
        return render(json: { error: "freee 未接続。設定から接続してください。" }, status: :bad_request) unless conn&.identity

        importer = Freee::ExpenseImporter.new(connection: conn, user: current_user)
        return render(json: { error: "freee 再ログインに失敗しました" }, status: :bad_request) unless importer.refresh_session!

        result = importer.import!(
          start_date: params[:start_date].presence || "2025-01-01",
          end_date: params[:end_date].presence || Date.current.to_s
        )
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/business_expenses/sync_freee_banks
      # freee に連携済みの全口座(銀行 + クレカ/VISA)を金融機関と同期(最新明細を取り込む)。
      def sync_freee_banks
        conn = current_user.freee_connection
        return render(json: { error: "freee 未接続。設定から接続してください。" }, status: :bad_request) unless conn&.identity

        importer = Freee::ExpenseImporter.new(connection: conn, user: current_user)
        return render(json: { error: "freee 再ログインに失敗しました" }, status: :bad_request) unless importer.refresh_session!

        render json: { results: importer.sync_accounts! }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/business_expenses/freee_wallet_txns?start_date=&end_date=
      # freeeの「自動で経理」相当: 銀行/カードの未処理明細に推奨科目を付けて返す(保存はしない)。
      # フロントで科目を選び import_commit で確定する。
      def freee_wallet_txns
        conn = current_user.freee_connection
        return render(json: { error: "freee 未接続。設定から接続してください。" }, status: :bad_request) unless conn&.identity

        importer = Freee::ExpenseImporter.new(connection: conn, user: current_user)
        return render(json: { error: "freee 再ログインに失敗しました" }, status: :bad_request) unless importer.refresh_session!

        rows = importer.unreconciled_txns(
          start_date: params[:start_date].presence || 3.months.ago.to_date.to_s,
          end_date: params[:end_date].presence || Date.current.to_s
        )
        render json: { rows: rows, count: rows.size, duplicate_count: rows.count { |r| r[:duplicate] } }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def require_admin
        render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
      end

      def set_record
        @record = current_user.business_expenses.find(params[:id])
      end

      def summarize(records)
        by_category = records.group_by(&:account_category).map do |category, rows|
          { category: category || "未分類", total: rows.sum(&:deductible_amount), count: rows.size }
        end.sort_by { |row| -row[:total] }
        {
          total: records.sum { |r| r.amount.to_i },
          deductible_total: records.sum(&:deductible_amount),
          count: records.size,
          needs_review_count: records.count { |r| r.status == "needs_review" },
          by_category: by_category
        }
      end

      def serialize(r)
        {
          id: r.id,
          expense_date: r.expense_date&.iso8601,
          store_name: r.store_name,
          amount: r.amount,
          tax_rate: r.tax_rate,
          account_category: r.account_category,
          memo: r.memo,
          business_ratio: r.business_ratio,
          deductible_amount: r.deductible_amount,
          status: r.status,
          ai_confidence: r.ai_confidence,
          has_receipt: r.receipt_data.present?,
          payment_source: r.payment_source,
          payment_method: r.payment_method,
          created_at: r.created_at&.iso8601
        }
      end
    end
  end
end
