Rails.application.routes.draw do
  devise_for :users,
    path: "api/v1/auth",
    path_names: { sign_in: "sign_in", sign_out: "sign_out", registration: "sign_up" },
    controllers: {
      sessions: "api/v1/auth/sessions",
      registrations: "api/v1/auth/registrations",
      omniauth_callbacks: "api/v1/auth/omniauth_callbacks"
    }

  namespace :api do
    namespace :v1 do
      get   "me", to: "me#show"
      patch "me", to: "me#update"
      post  "me/import_schedule", to: "me#import_schedule"

      get    "team_schedules",        to: "team_schedules#index"
      post   "team_schedules",        to: "team_schedules#create"
      post   "team_schedules/import", to: "team_schedules#import"
      post   "team_schedules/export", to: "team_schedules#export"
      patch  "team_schedules/:id",    to: "team_schedules#update"

      resources :work_reports, only: [:index, :create, :update, :destroy] do
        collection do
          post :clock_in
          post :clock_out
          post :voice_command
          post :transcribe
          post :import_progress
          post :append_task
        end
      end

      resources :expenses, only: [:index, :create, :update, :destroy]

      get "exports/work_report.xlsx", to: "exports#work_report"
      get "exports/expense.xlsx",     to: "exports#expense"
      get "exports/expense.pdf",      to: "exports#expense_pdf"
      get "exports/invoice.pdf",      to: "exports#invoice"
      post "exports/purchase_order.pdf", to: "exports#purchase_order"
      post "exports/pick_dir",            to: "exports#pick_local_dir"
      get  "exports/list_dirs",           to: "exports#list_local_dirs"

      get   "invoice_setting", to: "invoice_settings#show"
      patch "invoice_setting", to: "invoice_settings#update"
      get   "invoice_preview", to: "invoice_settings#preview"

      get   "purchase_order_settings",     to: "purchase_order_settings#index"
      get   "purchase_order_setting",      to: "purchase_order_settings#show"
      patch "purchase_order_setting",      to: "purchase_order_settings#update"
      delete "purchase_order_setting",     to: "purchase_order_settings#destroy"

      get   "monthly_setting", to: "monthly_settings#show"
      patch "monthly_setting", to: "monthly_settings#update"

      # バックログ
      resources :todos, only: [:index, :create, :update, :destroy]

      get   "backlog/setting",    to: "backlog#show_setting"
      patch "backlog/setting",    to: "backlog#update_setting"
      post  "backlog/test",       to: "backlog#test_connection"
      post  "backlog/sync",       to: "backlog#sync"
      get   "backlog/tasks",      to: "backlog#tasks"
      get   "backlog/tasks_on_date", to: "backlog#tasks_on_date"
      get   "backlog/tasks/:issue_key/comments", to: "backlog#task_comments"
      post  "backlog/tasks",       to: "backlog#create_task"
      patch "backlog/tasks/:id",  to: "backlog#update_task"
      delete "backlog/tasks/:id", to: "backlog#destroy_task"
      post  "backlog/reorder",    to: "backlog#reorder"
      post  "backlog/import_sheet", to: "backlog#import_sheet"
      post  "backlog/export_sheet", to: "backlog#export_sheet"
      get   "backlog/sheet_tabs",   to: "backlog#sheet_tabs"
      post  "backlog/sync_to_work_reports", to: "backlog#sync_to_work_reports"
      post  "work_reports/apply_transit",  to: "work_reports#apply_transit"
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
