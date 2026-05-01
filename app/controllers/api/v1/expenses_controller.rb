module Api
  module V1
    class ExpensesController < BaseController
      before_action :set_expense, only: [ :update, :destroy ]

      def index
        year, month = parse_month
        target = viewing_user
        period = target.period_for(year, month)
        render json: {
          period: { from: period.first, to: period.last },
          expenses: target.expenses.in_range(period).map { |e| serialize(e) }
        }
      end

      def create
        expense = current_user.expenses.create!(expense_params)
        render json: serialize(expense), status: :created
      end

      def update
        @expense.update!(expense_params)
        render json: serialize(@expense)
      end

      def destroy
        @expense.destroy!
        head :no_content
      end

      private

      def set_expense
        @expense = current_user.expenses.find(params[:id])
      end

      def expense_params
        params.permit(:expense_date, :purpose, :transport_type, :from_station,
                      :to_station, :round_trip, :receipt_no, :amount, :payee_or_line, :category,
                      :company_burden)
      end

      def serialize(e)
        {
          id: e.id, expense_date: e.expense_date, purpose: e.purpose,
          transport_type: e.transport_type, from_station: e.from_station,
          to_station: e.to_station, round_trip: e.round_trip,
          receipt_no: e.receipt_no, amount: e.amount, payee_or_line: e.payee_or_line,
          category: e.category, company_burden: e.company_burden
        }
      end
    end
  end
end
