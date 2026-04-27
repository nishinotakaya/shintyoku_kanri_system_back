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

ActiveRecord::Schema[8.0].define(version: 2026_04_26_140126) do
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
    t.index ["user_id"], name: "index_backlog_tasks_on_user_id"
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
    t.index ["user_id"], name: "index_expenses_on_user_id"
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

  create_table "jwt_denylists", force: :cascade do |t|
    t.string "jti"
    t.datetime "exp"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["jti"], name: "index_jwt_denylists_on_jti"
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
    t.index ["user_id", "category", "position"], name: "index_po_settings_on_user_cat_pos", unique: true
    t.index ["user_id"], name: "index_purchase_order_settings_on_user_id"
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
    t.index ["email"], name: "index_users_on_email", unique: true
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

  add_foreign_key "backlog_settings", "users"
  add_foreign_key "backlog_tasks", "users"
  add_foreign_key "expenses", "users"
  add_foreign_key "invoice_settings", "users"
  add_foreign_key "purchase_order_settings", "users"
  add_foreign_key "todos", "users"
  add_foreign_key "work_reports", "users"
end
