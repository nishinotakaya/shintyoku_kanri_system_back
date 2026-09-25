module Api
  module V1
    # freee 連携口座(銀行/カード)の明細台帳。freee の wallet_txns をこのシステムの DB で管理する。
    # 「口座を同期」でこっちの DB に取り込み、未登録の明細を経費として登録できる。
    class BankTransactionsController < BaseController
      before_action :require_keihi

      # GET /api/v1/bank_transactions?registered=false&month=YYYY-MM
      def index
        scope = current_user.bank_transactions.expense_side.order(txn_date: :desc, id: :desc)
        scope = scope.where(registered: ActiveModel::Type::Boolean.new.cast(params[:registered])) if params.key?(:registered)
        if params[:month].present?
          from = Date.strptime(params[:month], "%Y-%m")
          scope = scope.where(txn_date: from..from.end_of_month)
        end
        render json: {
          transactions: scope.limit(500).map { |t| serialize(t) },
          unregistered_count: current_user.bank_transactions.unregistered.expense_side.count,
          total_count: current_user.bank_transactions.expense_side.count
        }
      end

      # POST /api/v1/bank_transactions/sync  { start_date?, end_date? }
      # freee へ同期(口座→freee) → wallet_txns をこっちの DB に取込。
      def sync
        conn = current_user.freee_connection
        return render(json: { error: "freee 未接続" }, status: :bad_request) unless conn&.identity

        importer = Freee::ExpenseImporter.new(connection: conn, user: current_user)
        return render(json: { error: "freee 再ログインに失敗しました" }, status: :bad_request) unless importer.refresh_session!

        bank_results = importer.sync_accounts!            # 口座→freee(最新明細を金融機関から取込)
        ledger = importer.sync_bank_transactions!(         # freee→こっちの DB
          start_date: params[:start_date].presence || 6.months.ago.to_date.to_s,
          end_date: params[:end_date].presence || Date.current.to_s
        )
        render json: { accounts: bank_results, synced: ledger[:synced], unregistered_count: ledger[:unregistered] }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/bank_transactions/:id/register  { account_category?, business_ratio? }
      # 未登録明細を経費として登録(business_expense 作成 + registered=true)。
      def register
        txn = current_user.bank_transactions.find(params[:id])
        return render(json: { error: "登録済みです" }, status: :unprocessable_entity) if txn.registered && txn.business_expense_id

        # 冪等化: 同じ明細の business_expense が既にあれば二重作成しない（二重計上防止）
        hash = "freee_wtxn:#{txn.freee_wallet_txn_id}"
        existing = current_user.business_expenses.find_by(import_hash: hash)
        if existing
          txn.update!(registered: true, business_expense_id: existing.id)
          return render json: { registered: true, business_expense_id: existing.id, message: "既に登録済み" }
        end

        # 科目の決め方: ①画面で明示的に選んだ値 ②摘要ルール→AI→freee推奨(ExpenseCategoryDecider)。
        # 画面から何も指定されなければ AI が初期値を決める。確信度が低い判定は要確認で残す。
        chosen = known_category(params[:account_category])
        decision = chosen ? nil : ExpenseCategoryDecider.call([ {
          date: txn.txn_date&.iso8601,
          description: txn.description,
          amount: txn.amount,
          fallback_category: Freee::ExpenseImporter::ACCOUNT_ALIASES[txn.suggested_account_item] || txn.suggested_account_item
        } ]).first
        category = chosen || decision&.account_category

        expense = current_user.business_expenses.create!(
          expense_date: txn.txn_date || Date.current,
          store_name: txn.description.presence,
          amount: txn.amount,
          tax_rate: tax_rate_from(txn.suggested_tax_code),
          account_category: category,
          memo: [ txn.walletable_name, "freee明細" ].compact.join(" / "),
          business_ratio: (params[:business_ratio].presence || 100).to_i,
          status: (chosen || !decision.needs_review?) ? "confirmed" : "needs_review",
          ai_extracted_at: (Time.current if decision&.by_ai?),
          ai_confidence: (decision.confidence if decision&.by_ai?),
          source: "freee",
          import_hash: hash,
          payment_source: txn.walletable_name,
          payment_method: txn.payment_method,
          freee_synced: false
        )
        txn.update!(registered: true, business_expense_id: expense.id)
        render json: { registered: true, business_expense_id: expense.id }
      rescue ActiveRecord::RecordNotUnique
        txn.update!(registered: true)
        render json: { registered: true, message: "既に取込済み" }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/bank_transactions/:id/mark_private  { private: true|false }
      # プライベート(私的支出)印。true で未登録一覧から外す（経費計上しない）。
      def mark_private
        txn = current_user.bank_transactions.find(params[:id])
        is_private = params.key?(:private) ? ActiveModel::Type::Boolean.new.cast(params[:private]) : true
        txn.update!(is_private: is_private)
        render json: { id: txn.id, is_private: txn.is_private, unregistered_count: current_user.bank_transactions.unregistered.expense_side.count }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def require_keihi
        render(json: { error: "経費計上の利用権限がありません" }, status: :forbidden) unless current_user.can_use?(:keihi)
      end

      # ACCOUNT_CATEGORIES に無い名前(freee 独自の科目名・空文字)は採用しない
      def known_category(name)
        BusinessExpense::ACCOUNT_CATEGORIES.include?(name.to_s) ? name.to_s : nil
      end

      def tax_rate_from(code)
        # freee tax_code: 136=課対仕入10% / 軽減8% は別コード。大まかに判定
        code.to_i == 0 ? 0 : 10
      end

      def serialize(t)
        {
          id: t.id,
          txn_date: t.txn_date&.iso8601,
          amount: t.amount,
          description: t.description,
          walletable_name: t.walletable_name,
          payment_method: t.payment_method,
          suggested_account_item: t.suggested_account_item,
          registered: t.registered,
          business_expense_id: t.business_expense_id
        }
      end
    end
  end
end
