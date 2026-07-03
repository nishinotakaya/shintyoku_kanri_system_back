module Api
  module V1
    class ExpensesController < BaseController
      before_action :set_expense, only: [ :update, :destroy ]

      def index
        year, month = parse_month
        target = viewing_user
        period = target.period_for(year, month)
        mp = format("%04d-%02d", year, month)
        records = target.expenses.billed_in(mp, period).order(:expense_date)
        render json: {
          period: { from: period.first, to: period.last },
          expenses: records.map { |e| serialize(e) }
        }
      end

      def create
        expense = target_user.expenses.create!(expense_params)
        render json: serialize(expense), status: :created
      end

      def update
        @expense.update!(expense_params)
        render json: serialize(@expense)
      end

      def destroy
        # 電車賃(乗車区間あり)の立替を消したら、勤怠(work_report)の交通費欄もクリアする
        user = @expense.user
        was_transit = @expense.from_station.present? && @expense.to_station.present?
        date = @expense.expense_date
        category = @expense.category
        @expense.destroy!
        clear_work_report_transit(user, date, category) if was_transit
        head :no_content
      end

      # POST /api/v1/expenses/add_transit  { date, category?, as_user_id? }
      # 設定済みのデフォルト交通費(乗車区間・金額)で電車賃の立替を作り、勤怠の交通費欄にも反映する。
      def add_transit
        target = target_user
        date = params[:date].to_s
        category = params[:category].presence || "wings"
        return render(json: { error: "日付が不正です" }, status: :unprocessable_entity) if date.blank?
        if target.default_transit_from.blank? || target.default_transit_to.blank? || target.default_transit_fee.to_i <= 0
          return render(json: { error: "交通費のデフォルト設定がありません。設定画面で乗車区間・金額を登録してください。" }, status: :unprocessable_entity)
        end
        TeamScheduleExpenseSync.new(user: target, category: category).sync_one(date)
        expense = target.expenses.find_by(
          expense_date: date, category: category,
          from_station: target.default_transit_from, to_station: target.default_transit_to
        )
        render json: (expense ? serialize(expense) : {}), status: :created
      end

      private

      def target_user
        (current_user.admin? && params[:as_user_id].present?) ? (User.find_by(id: params[:as_user_id]) || current_user) : current_user
      end

      # 当該日・カテゴリの勤怠の乗車区間/交通費を空にする
      def clear_work_report_transit(user, date, category)
        wr = user.work_reports.find_by(work_date: date, category: category)
        wr&.update!(transit_section: nil, transit_fee: nil)
      end

      def set_expense
        scope = current_user.admin? ? Expense.all : current_user.expenses
        @expense = scope.find(params[:id])
      end

      def expense_params
        params.permit(:expense_date, :purpose, :transport_type, :from_station,
                      :to_station, :round_trip, :receipt_no, :amount, :payee_or_line, :category,
                      :company_burden, :excel_excluded, :billing_month)
      end

      def serialize(e)
        {
          id: e.id, expense_date: e.expense_date, purpose: e.purpose,
          transport_type: e.transport_type, from_station: e.from_station,
          to_station: e.to_station, round_trip: e.round_trip,
          receipt_no: e.receipt_no, amount: e.amount, payee_or_line: e.payee_or_line,
          category: e.category, company_burden: e.company_burden,
          excel_excluded: e.excel_excluded, billing_month: e.billing_month
        }
      end
    end
  end
end
