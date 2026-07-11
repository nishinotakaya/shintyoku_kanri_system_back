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
      get   "users/pickable", to: "me#pickable_users"

      # admin: ユーザー一覧 + 新規作成 + 招待メール + 権限/管理割当の更新
      namespace :admin do
        resources :users, only: [ :index, :create, :update ]
      end

      # スキルシート (機能フラグ can_use?(:skill_sheet) で利用可)
      get   "skill_sheets/targets", to: "skill_sheets#targets"
      get   "skill_sheets/tech_candidates", to: "skill_sheets#tech_candidates"
      post  "skill_sheets/import",  to: "skill_sheets#import"
      resources :skill_sheets, only: [ :index, :show, :create, :update, :destroy ] do
        member do
          post :review
          post :generate
          post :export
          post :analyze_tech
          post :suggest_techs
          post :generate_project_from_activities
          post :set_before
          get  :comments
          post "comments", action: :add_comment
          delete "comments/:comment_id", action: :destroy_comment
          get    :review_items
          post   "review_items", action: :create_review_item
          patch  "review_items/:item_id", action: :update_review_item
          delete "review_items/:item_id", action: :destroy_review_item
          patch  :connection, action: :update_connection
          post   :sync_external
          patch  :evaluations, action: :set_evaluations
        end
      end

      resources :interview_mindmaps, only: [ :index, :show, :create, :update, :destroy ] do
        collection do
          post :suggest_titles              # リサーチ+スキルシートからYouTubeタイトル案を生成
        end
        member do
          post  :import_bank
          post  :export_sheet
          post  :reset
          post  :reset_bank
          post  :generate_kanpe
          post  "nodes",                 action: :create_node
          post  "nodes/:node_id/expand", action: :expand_node
          post  "nodes/:node_id/speech", action: :speech
          post  "nodes/:node_id/proofread", action: :proofread_node
          patch "nodes/:node_id",        action: :update_node
          patch "nodes/:node_id/hover",  action: :hover_node
          get   "hovers",                action: :hovers
          delete "nodes/:node_id",       action: :destroy_node
        end
      end

      resources :heygen_assets, only: [ :index, :destroy ] do
        collection do
          post :clone_voice                  # 録音→自分の声をクローン
          post :create_avatar                # 写真→自分の顔アバター
          post :test_video                   # スタジオ内で声・顔のテスト動画を作る
        end
      end

      resources :invoice_certifications, only: [ :index, :create ] do
        collection do
          get "verify/:token", action: :verify  # 公開検証(認証不要)
        end
      end

      resources :interview_videos, only: [ :index, :show, :create, :update, :destroy ] do
        collection do
          get :options                       # アバター/ボイス/残高
        end
        member do
          post :generate_script              # 台本を AI 生成
          post :proofread                    # 台本をAI添削(矛盾は質問で返す)
          post :generate_kana                # 読み仮名(ひらがな)版を AI 生成
          post :generate_subtitles           # テロップを AI 生成(強調つき)
          post :photo,  action: :upload_photo # 写真→本人アバター
          post :render, action: :render_video # HeyGen に生成依頼
        end
      end

      # Canva Connect 連携(OAuth)
      get    "canva/status",     to: "canva#status"
      get    "canva/connect",    to: "canva#connect"
      get    "canva/callback",   to: "canva#callback"
      delete "canva/disconnect", to: "canva#disconnect"

      # YouTube サムネ生成
      get    "thumbnails/defaults", to: "thumbnails#defaults"
      resources :thumbnails, only: [ :index, :create, :destroy ] do
        collection do
          post :copy          # タイトル+要点→文言生成
          post :background    # gpt-image-1 で背景生成(data URL返却)
          post :to_canva      # 背景をCanvaに送りデザイン作成→編集URL
        end
        member do
          get  :image, action: :show           # PNG バイナリ配信(文字込み)
          get  :clean_background               # 文字なし背景PNG(再編集の下敷き用)
          post :import_canva                   # Canva書き出し→保存差し替え
        end
      end


      get    "team_schedules",        to: "team_schedules#index"
      post   "team_schedules",        to: "team_schedules#create"
      post   "team_schedules/import", to: "team_schedules#import"
      post   "team_schedules/export", to: "team_schedules#export"
      post   "team_schedules/sync_expenses", to: "team_schedules#sync_expenses"
      patch  "team_schedules/:id",    to: "team_schedules#update"

      resources :work_reports, only: [ :index, :create, :update, :destroy ] do
        collection do
          post :clock_in
          post :clock_out
          post :voice_command
          post :transcribe
          post :import_progress
          post :append_task
        end
      end

      resources :expenses, only: [ :index, :create, :update, :destroy ] do
        collection do
          post :add_transit
        end
      end

      # 確定申告用の事業経費 (レシート撮影→AI読取→勘定科目分類)
      resources :business_expenses, only: [ :index, :create, :update, :destroy ] do
        member do
          get :receipt
        end
        collection do
          post :import_csv         # 銀行/カード明細CSV → AI仕訳プレビュー
          post :import_commit      # プレビューで選択した行を一括登録
          post :import_freee       # freee登録済み経費(deal)を取込
          post :sync_freee_banks   # freee連携の全口座(銀行+クレカ)を同期
          get  :freee_wallet_txns  # freee「自動で経理」: 未処理明細+推奨科目
          post :report_bulk_to_freee # 選択した経費のうちfreee未連携分を一括計上
          post :bulk_destroy       # 選択した経費を一括削除
        end
      end
      # freee連携口座の明細台帳(銀行/カード)。同期→未登録明細→経費登録
      resources :bank_transactions, only: [ :index ] do
        member do
          post :register
          post :mark_private
        end
        collection { post :sync }
      end
      # 減価償却資産 + 確定申告集計 (admin専用)
      resources :fixed_assets, only: [ :index, :create, :update, :destroy ]
      get "tax_reports/summary",    to: "tax_reports#summary"
      get "tax_reports/export_csv", to: "tax_reports#export_csv"
      get "tax_reports/export_pdf", to: "tax_reports#export_pdf"
      post "tax_reports/advice",    to: "tax_reports#advice"

      resources :invoice_submissions, only: [ :index, :create, :update, :destroy ] do
        collection do
          post :bulk_create
          post :submit_bulk
        end
        member do
          post :report_to_freee
          post :submit
        end
      end
      resources :received_purchase_orders, only: [ :index, :show, :create, :update, :destroy ] do
        collection do
          post :extract
          post :upload
        end
        member do
          get :download
        end
      end
      resources :issued_invoice_pdfs, only: [ :index, :show, :update, :destroy ] do
        member do
          get  :download
          post :report_to_freee
          post :regenerate
          get  :versions
          post :revert
        end
      end

      # メール送付 (Gmail API 経由)
      post "emails/labop_draft",          to: "emails#labop_draft"
      post "emails/labop_send",           to: "emails#labop_send"
      post "emails/purchase_order_draft", to: "emails#purchase_order_draft"
      post "emails/purchase_order_bulk_draft", to: "emails#purchase_order_bulk_draft"
      post "emails/purchase_order_send",  to: "emails#purchase_order_send"
      post "emails/self_invoice_draft",   to: "emails#self_invoice_draft"
      post "emails/self_invoice_send",    to: "emails#self_invoice_send"
      post "emails/payment_notice_draft", to: "emails#payment_notice_draft"
      post "emails/payment_notice_send",  to: "emails#payment_notice_send"

      get "exports/work_report.xlsx", to: "exports#work_report"
      get "exports/expense.xlsx",     to: "exports#expense"
      get "exports/expense.pdf",      to: "exports#expense_pdf"
      get "exports/invoice.pdf",      to: "exports#invoice"
      # 集約版: 複数 submission を 1 PDF にマージ
      post "exports/merged_invoice.pdf", to: "exports#merged_invoice"
      post "exports/merged_expense.pdf", to: "exports#merged_expense"
      post "exports/merged_expense.xlsx", to: "exports#merged_expense_xlsx"
      post "exports/purchase_order.pdf", to: "exports#purchase_order"
      post "exports/pick_dir",            to: "exports#pick_local_dir"
      get  "exports/list_dirs",           to: "exports#list_local_dirs"

      get   "invoice_setting", to: "invoice_settings#show"
      patch "invoice_setting", to: "invoice_settings#update"
      get   "invoice_preview", to: "invoice_settings#preview"

      get   "purchase_order_settings",     to: "purchase_order_settings#index"
      patch "purchase_order_settings/reorder", to: "purchase_order_settings#reorder"
      get   "purchase_order_setting",      to: "purchase_order_settings#show"
      patch "purchase_order_setting",      to: "purchase_order_settings#update"
      delete "purchase_order_setting",     to: "purchase_order_settings#destroy"
      post "purchase_order_settings/:id/report_to_freee", to: "purchase_order_settings#report_to_freee", as: :purchase_order_setting_report_to_freee

      # 発注書 発行履歴
      resources :purchase_order_histories, only: [ :index, :create, :destroy ] do
        member do
          get :regenerate, defaults: { format: :pdf }
        end
      end

      get   "monthly_setting", to: "monthly_settings#show"
      patch "monthly_setting", to: "monthly_settings#update"

      # freee 会計連携
      get    "freee/setting",  to: "freee#show_setting"
      post   "freee/connect",  to: "freee#connect"
      post   "freee/test",     to: "freee#test_connection"
      delete "freee/setting",  to: "freee#disconnect"

      # 請求書 OCR (PDF を AI で読み取り)
      resources :scanned_invoices, only: [ :index, :show, :create, :update, :destroy ] do
        member do
          post  :report_to_freee
          get   :pdf
          patch :attach_pdf
        end
      end

      # バックログ
      resources :todos, only: [ :index, :create, :update, :destroy ]

      get   "backlog/setting",    to: "backlog#show_setting"
      patch "backlog/setting",    to: "backlog#update_setting"
      post  "backlog/test",       to: "backlog#test_connection"
      post  "backlog/sync",       to: "backlog#sync"
      post  "backlog/sync_notion", to: "backlog#sync_notion"
      get   "backlog/tasks",      to: "backlog#tasks"
      get   "backlog/tasks_on_date", to: "backlog#tasks_on_date"
      get   "backlog/tasks/:issue_key/comments", to: "backlog#task_comments"
      post  "backlog/tasks/:issue_key/comments", to: "backlog#create_task_comment"
      patch  "backlog/tasks/:issue_key/comments/:comment_id", to: "backlog#update_task_comment"
      delete "backlog/tasks/:issue_key/comments/:comment_id", to: "backlog#destroy_task_comment"
      get   "backlog/users",                  to: "backlog#users"
      post  "backlog/attachments",            to: "backlog#create_attachment"
      post  "backlog/ai_polish",              to: "backlog#ai_polish"
      post  "backlog/tasks",       to: "backlog#create_task"
      patch "backlog/tasks/:id",  to: "backlog#update_task"
      delete "backlog/tasks/:id", to: "backlog#destroy_task"
      post  "backlog/reorder",    to: "backlog#reorder"
      post  "backlog/import_sheet", to: "backlog#import_sheet"
      post  "backlog/export_sheet", to: "backlog#export_sheet"
      get   "backlog/sheet_tabs",   to: "backlog#sheet_tabs"
      post  "backlog/sync_to_work_reports", to: "backlog#sync_to_work_reports"
      # Backlog Git（GitHub風レビュー画面）
      get  "backlog_git/repositories",  to: "backlog_git#repositories"
      get  "backlog_git/pull_requests", to: "backlog_git#pull_requests"
      get  "backlog_git/tree",          to: "backlog_git#tree"
      get  "backlog_git/file",          to: "backlog_git#file"
      get  "backlog_git/pr_detail",     to: "backlog_git#pr_detail"
      post "backlog_git/comment",       to: "backlog_git#post_comment"
      post "backlog_git/review",        to: "backlog_git#post_review"
      get    "backlog_git/notes",       to: "backlog_git#notes"
      post   "backlog_git/notes",       to: "backlog_git#create_note"
      delete "backlog_git/notes/:id",   to: "backlog_git#destroy_note"
      # GitHub 連携（PAT 方式）
      get   "github/setting",        to: "github#show_setting"
      patch "github/setting",        to: "github#update_setting"
      post  "github/test",           to: "github#test_connection"
      get   "github/repositories",   to: "github_repos#repositories"
      get   "github/pull_requests",  to: "github_repos#pull_requests"
      get   "github/pr_detail",      to: "github_repos#pr_detail"
      post  "github/comment",        to: "github_repos#create_comment"
      post  "github/review_comment", to: "github_repos#create_review_comment"
      get   "github/notifications",  to: "github_repos#notifications"
      # Backlog 対応ログ（活動履歴）月次ビュー
      get   "backlog_activities/targets", to: "backlog_activities#targets"
      post  "backlog_activities/sync",    to: "backlog_activities#sync"
      post  "backlog_activities/export",  to: "backlog_activities#export"
      post  "backlog_activities/export_notion", to: "backlog_activities#export_notion"
      post  "backlog_activities/import_notion", to: "backlog_activities#import_notion"
      post  "backlog_activities/import_doc_hub", to: "backlog_activities#import_doc_hub"
      post  "backlog_activities/import",  to: "backlog_activities#import"
      patch "backlog_activities/note",    to: "backlog_activities#update_note"
      patch "backlog_activities/notion_task", to: "backlog_activities#update_notion_task"
      get   "backlog_activities",         to: "backlog_activities#index"
      post  "work_reports/apply_transit",  to: "work_reports#apply_transit"

      # Notion (WBS タスク) 連携
      resources :notion_tasks, only: [ :index, :update ] do
        collection do
          post :sync
        end
      end

      # 進捗管理(/progress)のワークスペース切替
      resources :progress_workspaces, only: [ :index, :create, :update, :destroy ]
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
