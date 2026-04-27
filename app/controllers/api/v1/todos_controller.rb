module Api
  module V1
    class TodosController < BaseController
      before_action :set_todo, only: [ :update, :destroy ]

      def index
        active = current_user.todos.active
        completed = current_user.todos.completed_list.limit(10)
        render json: { active: active.map { |t| ser(t) }, completed: completed.map { |t| ser(t) } }
      end

      def create
        todo = current_user.todos.create!(todo_params.merge(completed: false))
        render json: ser(todo), status: :created
      end

      def update
        @todo.update!(todo_params)
        render json: ser(@todo)
      end

      def destroy
        @todo.destroy!
        head :no_content
      end

      private

      def set_todo
        @todo = current_user.todos.find(params[:id])
      end

      def todo_params
        params.permit(:title, :description, :due_date, :completed, :priority, :category)
      end

      def ser(t)
        { id: t.id, title: t.title, description: t.description, due_date: t.due_date,
          completed: t.completed, priority: t.priority, category: t.category,
          created_at: t.created_at }
      end
    end
  end
end
