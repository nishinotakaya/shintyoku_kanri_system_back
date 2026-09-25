module Api
  module V1
    # 確定申告用の事業経費 (レシート撮影→AI読取→勘定科目分類)。
    # Phase 1 は西野(admin)専用。立替金(expenses)とは完全別管理。
    class BusinessExpensesController < BaseController
      include FreeeReportable
      before_action :require_admin
      before_action :set_record, only: [ :update, :destroy, :receipt ]

      # 1回の AI 仕訳で扱う上限。まとめて投げすぎないための歯止め
      CLASSIFY_LIMIT = 200

      # GET /api/v1/business_expenses?month=YYYY-MM&account_category=
      def index
        scope = current_user.business_expenses.without_receipt_data.order(expense_date: :desc, id: :desc)
        scope = scope.in_month(params[:month])
        scope = scope.where(account_category: params[:account_category]) if params[:account_category].present?
        scope = scope.where(status: params[:status]) if params[:status].present?
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
        attrs = params.permit(:expense_date, :store_name, :amount, :tax_rate, :account_category, :memo, :business_ratio, :status, :excluded_reason)
        updates = attrs.to_h.compact_blank.merge(params[:memo] ? { memo: params[:memo].to_s } : {})
        # 対象外を解除(confirmed 等に戻す)したら理由も消す
        updates[:excluded_reason] = nil if updates[:status].present? && updates[:status] != "excluded"
        @record.update!(updates)
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
      # freeeの「自動で経理」相当: 銀行/カードの未処理明細に科目を付けて返す(保存はしない)。
      # 科目の初期値は AI(摘要ルール→AI)が決め、freee の推奨科目は予備に回す。
      # フロントで科目を確認・変更し import_commit で確定する。
      def freee_wallet_txns
        conn = current_user.freee_connection
        return render(json: { error: "freee 未接続。設定から接続してください。" }, status: :bad_request) unless conn&.identity

        importer = Freee::ExpenseImporter.new(connection: conn, user: current_user)
        return render(json: { error: "freee 再ログインに失敗しました" }, status: :bad_request) unless importer.refresh_session!

        rows = decide_categories(importer.unreconciled_txns(
          start_date: params[:start_date].presence || 3.months.ago.to_date.to_s,
          end_date: params[:end_date].presence || Date.current.to_s
        ))
        render json: { rows: rows, count: rows.size, duplicate_count: rows.count { |r| r[:duplicate] } }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/business_expenses/report_bulk_to_freee  { ids: [] }
      # 選択した経費のうち freee 未連携分(freee_synced: false)を一括計上する。連携済みはスキップ扱い。
      def report_bulk_to_freee
        ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
        return render(json: { error: "対象を選択してください" }, status: :unprocessable_entity) if ids.empty?

        conn = current_user.freee_connection
        return render(json: { error: "freee 未接続です。設定から接続してください" }, status: :bad_request) unless conn&.identity
        return render(json: { error: "freee 再ログインに失敗しました" }, status: :bad_request) unless refresh_freee_session!(conn)

        result = Freee::BulkExpenseReporter.new(user: current_user, connection: conn).call(ids)
        render json: { succeeded: result.succeeded, skipped: result.skipped, failed: result.failed }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/business_expenses/classify_uncategorized  { ids?: [], month?: "YYYY-MM" }
      # 「未分類」で登録されてしまった経費を、後から AI(摘要ルール→AI)でまとめて仕訳する。
      # 既に科目が入っている行と対象外(excluded)は触らない。
      # 確信度が低い判定は科目を入れた上で要確認に落とし、人の目に掛ける。
      def classify_uncategorized
        scope = current_user.business_expenses.without_receipt_data
                            .where(account_category: nil).where.not(status: "excluded")
        ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
        scope = ids.any? ? scope.where(id: ids) : scope.in_month(params[:month])
        records = scope.order(expense_date: :desc, id: :desc).limit(CLASSIFY_LIMIT).to_a
        return render json: { updated: 0, skipped: 0, total: 0 } if records.empty?

        decisions = ExpenseCategoryDecider.call(records.map { |record|
          { date: record.expense_date&.iso8601, description: record.store_name.presence || record.memo, amount: record.amount }
        })
        updated = 0
        records.zip(decisions).each do |record, decision|
          next unless decision.decided?
          record.update!(
            account_category: decision.account_category,
            status: decision.needs_review? ? "needs_review" : record.status,
            ai_extracted_at: decision.by_ai? ? Time.current : record.ai_extracted_at,
            ai_confidence: decision.by_ai? ? decision.confidence : record.ai_confidence
          )
          updated += 1
        end
        render json: { updated: updated, skipped: records.size - updated, total: records.size }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/business_expenses/bulk_destroy  { ids: [] }
      # 選択した経費を一括削除する。current_user 所有分以外は対象外(黙って無視)。
      def bulk_destroy
        ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
        deleted = current_user.business_expenses.where(id: ids).destroy_all
        render json: { deleted: deleted.size }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # admin は常に可。非 admin は feature_flags["keihi"] が ON のユーザーも利用可。
      def require_admin
        return if current_user.can_use?(:keihi)
        render(json: { error: "経費計上の利用権限がありません" }, status: :forbidden)
      end

      def set_record
        @record = current_user.business_expenses.find(params[:id])
      end

      # 未処理明細の科目の初期値を AI に決めさせる。freee の推奨科目は予備(fallback)に回す。
      # 取込済み(duplicate)の行は画面で選べないので AI には投げない。
      def decide_categories(rows)
        targets = rows.reject { |row| row[:duplicate] }
        return rows if targets.empty?

        decisions = ExpenseCategoryDecider.call(targets.map { |row|
          { date: row[:date], description: row[:description], amount: row[:amount], fallback_category: row[:account_category] }
        })
        by_hash = targets.each_with_index.to_h { |row, index| [ row[:import_hash], decisions[index] ] }
        rows.map do |row|
          decision = by_hash[row[:import_hash]]
          decision ? row.merge(account_category: decision.account_category, confidence: decision.confidence) : row
        end
      end

      # 一覧には対象外(excluded)も返すが、金額の集計からは外す
      def summarize(records)
        counted_records = records.reject(&:excluded?)
        by_category = counted_records.group_by(&:account_category).map do |category, rows|
          { category: category || "未分類", total: rows.sum(&:deductible_amount), count: rows.size }
        end.sort_by { |row| -row[:total] }
        {
          total: counted_records.sum { |r| r.amount.to_i },
          deductible_total: counted_records.sum(&:deductible_amount),
          count: counted_records.size,
          needs_review_count: counted_records.count { |r| r.status == "needs_review" },
          excluded_count: records.count(&:excluded?),
          excluded_total: records.select(&:excluded?).sum { |r| r.amount.to_i },
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
          excluded_reason: r.excluded_reason,
          ai_confidence: r.ai_confidence,
          has_receipt: r.receipt_attached?,
          payment_source: r.payment_source,
          payment_method: r.payment_method,
          freee_synced: r.freee_synced,
          source: r.source,
          created_at: r.created_at&.iso8601
        }
      end
    end
  end
end
