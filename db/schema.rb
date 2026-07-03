# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_07_03_000004) do
  create_table "backlog_activities", force: :cascade do |t|
    t.integer "user_id", null: false
    t.bigint "activity_id", null: false
    t.string "project_key"
    t.string "issue_key"
    t.string "summary"
    t.string "activity_type"
    t.text "content"
    t.date "occurred_on"
    t.string "month"
    t.string "url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["issue_key"], name: "index_backlog_activities_on_issue_key"
    t.index ["user_id", "activity_id"], name: "index_backlog_activities_on_user_id_and_activity_id", unique: true
    t.index ["user_id", "month"], name: "index_backlog_activities_on_user_id_and_month"
    t.index ["user_id"], name: "index_backlog_activities_on_user_id"
  end

  create_table "backlog_completions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "issue_key", null: false
    t.date "completed_on"
    t.datetime "synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "issue_key"], name: "index_backlog_completions_on_user_issue", unique: true
  end

  create_table "backlog_settings", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "backlog_url"
    t.string "backlog_email"
    t.string "backlog_password"
    t.integer "board_id"
    t.integer "user_backlog_id"
    t.text "session_cookie"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "api_key"
    t.text "memo"
    t.text "assignee_ids"
    t.string "assignee_name_filter"
    t.index ["user_id"], name: "index_backlog_settings_on_user_id"
  end

  create_table "backlog_summary_notes", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "month", null: false
    t.string "issue_key", null: false
    t.text "note"
    t.string "status_override"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "notion_block_id"
    t.index ["user_id", "month", "issue_key"], name: "index_backlog_summary_notes_on_user_month_issue", unique: true
    t.index ["user_id"], name: "index_backlog_summary_notes_on_user_id"
  end

  create_table "backlog_tasks", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "issue_key"
    t.string "summary"
    t.integer "status_id"
    t.string "status_name"
    t.date "created_on"
    t.date "completed_on"
    t.date "due_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "start_date"
    t.date "end_date"
    t.text "memo"
    t.integer "position"
    t.float "progress_value"
    t.date "deploy_date"
    t.string "deploy_note"
    t.string "source"
    t.string "assignee_name"
    t.integer "assignee_id"
    t.string "url"
    t.boolean "did_previous", default: false, null: false
    t.boolean "do_today", default: false, null: false
    t.index ["user_id"], name: "index_backlog_tasks_on_user_id"
  end

  create_table "business_expenses", force: :cascade do |t|
    t.integer "user_id", null: false
    t.date "expense_date"
    t.string "store_name"
    t.integer "amount"
    t.integer "tax_rate", default: 10, null: false
    t.string "account_category"
    t.string "memo"
    t.integer "business_ratio", default: 100, null: false
    t.string "status", default: "needs_review", null: false
    t.binary "receipt_data"
    t.string "content_type"
    t.datetime "ai_extracted_at"
    t.integer "ai_confidence"
    t.text "ai_raw"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source", default: "receipt", null: false
    t.string "import_hash"
    t.index ["user_id", "expense_date"], name: "index_business_expenses_on_user_id_and_expense_date"
    t.index ["user_id", "import_hash"], name: "index_business_expenses_on_user_id_and_import_hash"
  end

  create_table "expenses", force: :cascade do |t|
    t.integer "user_id", null: false
    t.date "expense_date"
    t.string "purpose"
    t.string "transport_type"
    t.string "from_station"
    t.string "to_station"
    t.boolean "round_trip"
    t.string "receipt_no"
    t.integer "amount"
    t.string "payee_or_line"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "category"
    t.boolean "company_burden", default: true, null: false
    t.boolean "excel_excluded", default: false, null: false
    t.string "billing_month"
    t.index ["billing_month"], name: "index_expenses_on_billing_month"
    t.index ["user_id"], name: "index_expenses_on_user_id"
  end

  create_table "fixed_assets", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "name", null: false
    t.date "acquired_on", null: false
    t.integer "cost", null: false
    t.integer "useful_life_years", null: false
    t.integer "business_ratio", default: 100, null: false
    t.string "memo"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_fixed_assets_on_user_id"
  end

  create_table "freee_connections", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "company_id"
    t.string "company_name"
    t.text "session_cookie"
    t.string "csrf_token"
    t.string "identity"
    t.text "password_encrypted"
    t.datetime "last_connected_at"
    t.integer "last_status_code"
    t.string "status", default: "disconnected"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_freee_connections_on_user_id", unique: true
  end

  create_table "generated_thumbnails", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "interview_mindmap_id"
    t.string "title", default: "", null: false
    t.text "prompt"
    t.text "copy_json"
    t.string "source", default: "gpt_image", null: false
    t.string "canva_design_id"
    t.string "canva_edit_url"
    t.string "content_type", default: "image/png", null: false
    t.integer "byte_size", default: 0, null: false
    t.binary "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.binary "clean_background"
    t.index ["interview_mindmap_id"], name: "index_generated_thumbnails_on_interview_mindmap_id"
    t.index ["user_id"], name: "index_generated_thumbnails_on_user_id"
  end

  create_table "heygen_assets", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "kind", null: false
    t.string "ref_id", null: false
    t.string "name"
    t.string "status", default: "ready", null: false
    t.string "preview_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "kind"], name: "index_heygen_assets_on_user_id_and_kind"
  end

  create_table "interview_mindmap_nodes", force: :cascade do |t|
    t.integer "interview_mindmap_id", null: false
    t.integer "parent_id"
    t.string "kind", default: "question", null: false
    t.text "text"
    t.integer "position", default: 0
    t.boolean "checked", default: false, null: false
    t.boolean "expanded", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source"
    t.integer "hovered_by_user_id"
    t.datetime "hovered_at"
    t.index ["interview_mindmap_id", "parent_id", "position"], name: "idx_imnodes_tree"
  end

  create_table "interview_mindmaps", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "skill_sheet_id"
    t.string "title"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "spreadsheet_url"
    t.string "mode", default: "interview", null: false
    t.index ["user_id"], name: "index_interview_mindmaps_on_user_id"
  end

  create_table "interview_videos", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "interview_mindmap_id"
    t.string "title"
    t.text "script"
    t.text "subtitles"
    t.string "avatar_kind", default: "avatar"
    t.string "avatar_id"
    t.string "talking_photo_id"
    t.string "photo_url"
    t.string "voice_id"
    t.string "heygen_video_id"
    t.string "status", default: "draft", null: false
    t.text "video_url"
    t.float "duration"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "script_kana"
    t.index ["interview_mindmap_id"], name: "index_interview_videos_on_interview_mindmap_id"
    t.index ["user_id"], name: "index_interview_videos_on_user_id"
  end

  create_table "invoice_settings", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "client_name"
    t.string "subject"
    t.string "item_label"
    t.integer "unit_price"
    t.integer "tax_rate"
    t.integer "payment_due_days"
    t.string "issuer_name"
    t.string "registration_no"
    t.string "postal_code"
    t.string "address"
    t.string "tel"
    t.string "email"
    t.string "bank_info"
    t.text "default_items"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "category"
    t.string "payment_due_type"
    t.string "honorific"
    t.index ["user_id"], name: "index_invoice_settings_on_user_id"
  end

  create_table "invoice_submissions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "year"
    t.integer "month"
    t.string "category"
    t.string "status"
    t.datetime "submitted_at"
    t.datetime "reviewed_at"
    t.integer "reviewer_id"
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "total_override"
    t.string "item_label_override"
    t.string "subject_override"
    t.string "kind", default: "invoice", null: false
    t.text "items_override"
    t.date "application_date_override"
    t.integer "received_purchase_order_id"
    t.string "purchase_order_no_override"
    t.datetime "paid_at"
    t.text "review_comment"
    t.string "freee_deal_id"
    t.datetime "freee_reported_at"
    t.date "due_date_override"
    t.string "registration_no_override"
    t.string "bank_info_override"
    t.index ["kind"], name: "index_invoice_submissions_on_kind"
    t.index ["paid_at"], name: "index_invoice_submissions_on_paid_at"
    t.index ["received_purchase_order_id"], name: "index_invoice_submissions_on_received_purchase_order_id"
    t.index ["user_id"], name: "index_invoice_submissions_on_user_id"
  end

  create_table "issued_invoice_pdf_versions", force: :cascade do |t|
    t.integer "issued_invoice_pdf_id", null: false
    t.integer "user_id"
    t.string "kind"
    t.string "file_format"
    t.integer "year"
    t.integer "month"
    t.string "category"
    t.string "purchase_order_no"
    t.text "source_submission_ids"
    t.boolean "merged"
    t.integer "total_amount"
    t.string "filename"
    t.binary "file_data"
    t.string "note"
    t.text "items_override"
    t.datetime "original_generated_at"
    t.string "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["issued_invoice_pdf_id"], name: "index_issued_invoice_pdf_versions_on_issued_invoice_pdf_id"
  end

  create_table "issued_invoice_pdfs", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "kind", null: false
    t.string "file_format", default: "pdf", null: false
    t.integer "year"
    t.integer "month"
    t.string "category"
    t.string "purchase_order_no"
    t.text "source_submission_ids"
    t.boolean "merged", default: false, null: false
    t.integer "total_amount"
    t.string "filename", null: false
    t.binary "file_data", null: false
    t.string "note"
    t.datetime "generated_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "freee_deal_id"
    t.datetime "freee_reported_at"
    t.date "application_date"
    t.text "items_override"
    t.index ["purchase_order_no"], name: "index_issued_invoice_pdfs_on_purchase_order_no"
    t.index ["user_id"], name: "index_issued_invoice_pdfs_on_user_id"
    t.index ["year", "month", "category"], name: "index_issued_invoice_pdfs_on_year_and_month_and_category"
  end

  create_table "jwt_denylists", force: :cascade do |t|
    t.string "jti"
    t.datetime "exp"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["jti"], name: "index_jwt_denylists_on_jti"
  end

  create_table "manager_assignments", force: :cascade do |t|
    t.integer "manager_id", null: false
    t.integer "managee_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["managee_id"], name: "index_manager_assignments_on_managee_id"
    t.index ["manager_id", "managee_id"], name: "index_manager_assignments_on_manager_id_and_managee_id", unique: true
  end

  create_table "monthly_settings", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "year", null: false
    t.integer "month", null: false
    t.date "application_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "year", "month"], name: "index_monthly_settings_on_user_id_and_year_and_month", unique: true
  end

  create_table "notion_tasks", force: :cascade do |t|
    t.string "notion_block_id", null: false
    t.string "wbs_level"
    t.string "title", null: false
    t.string "parent_task"
    t.string "assignee_name"
    t.string "assignee_notion_id"
    t.date "start_date"
    t.date "end_date"
    t.decimal "workload", precision: 6, scale: 2
    t.decimal "progress_rate", precision: 5, scale: 2
    t.string "status"
    t.string "priority"
    t.text "note"
    t.datetime "synced_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "start_date_prev"
    t.date "end_date_prev"
    t.decimal "progress_rate_prev", precision: 5, scale: 2
    t.string "status_prev"
    t.text "memo"
    t.index ["assignee_name"], name: "index_notion_tasks_on_assignee_name"
    t.index ["notion_block_id"], name: "index_notion_tasks_on_notion_block_id", unique: true
    t.index ["start_date", "end_date"], name: "index_notion_tasks_on_start_date_and_end_date"
  end

  create_table "purchase_order_histories", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "category"
    t.integer "position"
    t.string "order_no"
    t.string "subject"
    t.string "recipient_name"
    t.date "period_start"
    t.date "period_end"
    t.integer "total_amount"
    t.text "payload"
    t.datetime "issued_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "recipient_user_id"
    t.index ["recipient_user_id"], name: "index_purchase_order_histories_on_recipient_user_id"
    t.index ["user_id"], name: "index_purchase_order_histories_on_user_id"
  end

  create_table "purchase_order_settings", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "category"
    t.string "subject"
    t.string "issuer_company"
    t.string "issuer_representative"
    t.string "issuer_postal"
    t.string "issuer_address"
    t.string "recipient_name"
    t.string "recipient_postal"
    t.string "recipient_address"
    t.date "period_start"
    t.date "period_end"
    t.integer "closing_day"
    t.integer "hours_per_cycle"
    t.integer "rate_per_hour"
    t.integer "base_monthly"
    t.string "delivery_location"
    t.string "payment_method"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "unit"
    t.text "items"
    t.text "remarks"
    t.string "price_mode"
    t.integer "range_min"
    t.integer "range_max"
    t.integer "position", default: 0, null: false
    t.integer "recipient_user_id"
    t.string "order_no"
    t.string "freee_deal_id"
    t.datetime "freee_reported_at"
    t.index ["recipient_user_id"], name: "index_purchase_order_settings_on_recipient_user_id"
    t.index ["user_id", "category", "position"], name: "index_po_settings_on_user_cat_pos", unique: true
    t.index ["user_id"], name: "index_purchase_order_settings_on_user_id"
  end

  create_table "received_purchase_orders", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "order_no", null: false
    t.string "customer_name"
    t.string "category"
    t.string "subject"
    t.date "period_start"
    t.date "period_end"
    t.integer "total_amount"
    t.text "note"
    t.string "file_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.binary "file_data"
    t.string "filename"
    t.string "content_type"
    t.datetime "ai_extracted_at"
    t.text "ai_raw_text"
    t.index ["order_no"], name: "index_received_purchase_orders_on_order_no"
    t.index ["user_id"], name: "index_received_purchase_orders_on_user_id"
  end

  create_table "scanned_invoices", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "original_filename"
    t.string "partner_name"
    t.string "subject"
    t.integer "subtotal_amount"
    t.integer "tax_amount"
    t.integer "total_amount"
    t.date "issue_date"
    t.date "due_date"
    t.string "invoice_number"
    t.text "raw_text"
    t.json "raw_ai_response"
    t.string "status", default: "pending"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "freee_deal_id"
    t.datetime "freee_reported_at"
    t.text "pdf_data"
    t.string "content_type"
    t.index ["user_id"], name: "index_scanned_invoices_on_user_id"
  end

  create_table "skill_sheet_comments", force: :cascade do |t|
    t.integer "skill_sheet_id", null: false
    t.integer "author_user_id"
    t.string "author_name"
    t.string "target"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["skill_sheet_id"], name: "index_skill_sheet_comments_on_skill_sheet_id"
  end

  create_table "skill_sheet_evaluations", force: :cascade do |t|
    t.integer "skill_sheet_id", null: false
    t.string "label", null: false
    t.string "level", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["skill_sheet_id", "label"], name: "index_skill_sheet_evaluations_on_skill_sheet_id_and_label", unique: true
    t.index ["skill_sheet_id"], name: "index_skill_sheet_evaluations_on_skill_sheet_id"
  end

  create_table "skill_sheet_projects", force: :cascade do |t|
    t.integer "skill_sheet_id", null: false
    t.integer "position", default: 0
    t.string "period_from"
    t.string "period_to"
    t.text "description"
    t.text "role_scale"
    t.text "languages"
    t.text "db"
    t.text "server_os"
    t.text "tools"
    t.text "phases"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "title"
    t.string "wantedly_work_experience_uuid"
    t.string "anotherworks_resume_id"
    t.string "source", default: "import", null: false
    t.index ["skill_sheet_id", "position"], name: "index_skill_sheet_projects_on_skill_sheet_id_and_position"
  end

  create_table "skill_sheet_review_items", force: :cascade do |t|
    t.integer "skill_sheet_id", null: false
    t.string "target"
    t.string "field"
    t.text "issues"
    t.text "suggestion"
    t.boolean "applied", default: false, null: false
    t.string "source", default: "ai", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["skill_sheet_id"], name: "index_skill_sheet_review_items_on_skill_sheet_id"
  end

  create_table "skill_sheet_techs", force: :cascade do |t|
    t.integer "skill_sheet_id", null: false
    t.string "category"
    t.string "name"
    t.string "version"
    t.integer "months_used", default: 0
    t.string "last_used_on"
    t.integer "last_used_rank", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["skill_sheet_id", "category"], name: "index_skill_sheet_techs_on_skill_sheet_id_and_category"
  end

  create_table "skill_sheets", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "spreadsheet_url"
    t.string "spreadsheet_id"
    t.string "gid"
    t.string "engineer_name"
    t.string "age"
    t.string "gender"
    t.string "address"
    t.string "start_date"
    t.string "nearest_station"
    t.text "specialties"
    t.text "skills"
    t.text "duties"
    t.text "self_pr"
    t.text "raw_content"
    t.text "review_result"
    t.datetime "reviewed_at"
    t.datetime "synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "before_snapshot"
    t.text "youtube_self_pr"
    t.string "export_gid"
    t.string "template_type", default: "engineer", null: false
    t.index ["user_id"], name: "index_skill_sheets_on_user_id"
  end

  create_table "team_schedules", force: :cascade do |t|
    t.date "date"
    t.string "person"
    t.string "status"
    t.string "location"
    t.string "memo"
    t.string "year_month"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["date", "person"], name: "index_team_schedules_on_date_and_person", unique: true
    t.index ["year_month"], name: "index_team_schedules_on_year_month"
  end

  create_table "todos", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "title"
    t.text "description"
    t.date "due_date"
    t.boolean "completed"
    t.integer "priority"
    t.string "category"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_todos_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.string "display_name"
    t.string "company_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "openai_api_key"
    t.integer "closing_day", default: 25, null: false
    t.string "provider"
    t.string "uid"
    t.string "avatar_url"
    t.text "custom_off_days"
    t.string "default_transit_from"
    t.string "default_transit_to"
    t.integer "default_transit_fee"
    t.string "default_transit_line"
    t.text "transit_routes"
    t.text "commute_days"
    t.text "google_access_token"
    t.text "google_refresh_token"
    t.datetime "google_token_expires_at"
    t.boolean "can_issue_orders", default: false, null: false
    t.string "postal_code"
    t.string "address"
    t.string "attendance_schedule_url"
    t.string "local_save_dir"
    t.integer "linked_user_id"
    t.string "progress_sheet_url"
    t.text "feature_flags"
    t.string "dev_language"
    t.text "wantedly_token"
    t.text "anotherworks_token"
    t.string "heygen_api_key"
    t.text "video_script_context"
    t.text "canva_access_token"
    t.text "canva_refresh_token"
    t.datetime "canva_token_expires_at"
    t.string "canva_oauth_state"
    t.string "canva_oauth_verifier"
    t.text "seal_image"
    t.boolean "invoice_registered", default: false, null: false
    t.index ["canva_oauth_state"], name: "index_users_on_canva_oauth_state"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["linked_user_id"], name: "index_users_on_linked_user_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "work_reports", force: :cascade do |t|
    t.integer "user_id", null: false
    t.date "work_date", null: false
    t.string "content"
    t.decimal "hours", precision: 4, scale: 2
    t.time "clock_in"
    t.time "clock_out"
    t.integer "break_minutes", default: 0
    t.string "transit_section"
    t.integer "transit_fee"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "category"
    t.index ["user_id", "work_date", "category"], name: "index_work_reports_on_user_id_and_work_date_and_category", unique: true
    t.index ["user_id"], name: "index_work_reports_on_user_id"
  end

  add_foreign_key "backlog_activities", "users"
  add_foreign_key "backlog_settings", "users"
  add_foreign_key "backlog_summary_notes", "users"
  add_foreign_key "backlog_tasks", "users"
  add_foreign_key "expenses", "users"
  add_foreign_key "freee_connections", "users"
  add_foreign_key "generated_thumbnails", "interview_mindmaps"
  add_foreign_key "generated_thumbnails", "users"
  add_foreign_key "invoice_settings", "users"
  add_foreign_key "invoice_submissions", "users"
  add_foreign_key "purchase_order_histories", "users"
  add_foreign_key "purchase_order_histories", "users", column: "recipient_user_id"
  add_foreign_key "purchase_order_settings", "users"
  add_foreign_key "purchase_order_settings", "users", column: "recipient_user_id"
  add_foreign_key "scanned_invoices", "users"
  add_foreign_key "skill_sheet_evaluations", "skill_sheets"
  add_foreign_key "skill_sheet_review_items", "skill_sheets"
  add_foreign_key "todos", "users"
  add_foreign_key "users", "users", column: "linked_user_id"
  add_foreign_key "work_reports", "users"
end
