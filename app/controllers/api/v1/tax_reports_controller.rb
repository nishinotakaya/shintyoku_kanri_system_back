require "csv"

module Api
  module V1
    # 確定申告支援: 年間の売上×経費(科目別)×減価償却→差引所得の集計と、e-Tax転記用CSV出力。
    # admin(西野)専用。売上=承認済みの自分の請求書(invoice_submissions)、経費=business_expenses(按分後)。
    class TaxReportsController < BaseController
      before_action :require_admin

      # GET /api/v1/tax_reports/summary?year=2026
      def summary
        year = target_year
        render json: build_summary(year)
      end

      # GET /api/v1/tax_reports/export_csv?year=2026&kind=summary|details
      # e-Tax(確定申告書等作成コーナー)転記用のCSV。Excelで開けるようBOM付きUTF-8。
      def export_csv
        year = target_year
        csv = params[:kind] == "details" ? details_csv(year) : summary_csv(year)
        filename = params[:kind] == "details" ? "経費明細_#{year}年.csv" : "青色申告集計_#{year}年.csv"
        send_data "﻿" + csv, type: "text/csv; charset=utf-8", filename: filename, disposition: "attachment"
      end

      private

      def require_admin
        render(json: { error: "admin only" }, status: :forbidden) unless current_user.admin?
      end

      def target_year
        params[:year].presence&.to_i || Date.current.year
      end

      def year_expenses(year)
        current_user.business_expenses.where(expense_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
      end

      def year_incomes(year)
        InvoiceSubmission.where(user_id: current_user.id, kind: "invoice", status: "approved", year: year)
      end

      def build_summary(year)
        expenses = year_expenses(year).to_a
        incomes = year_incomes(year).to_a
        assets = current_user.fixed_assets.to_a
        depreciation_total = assets.sum { |a| a.depreciation_for(year) }

        by_category = expenses.group_by(&:account_category).map do |category, rows|
          { category: category || "未分類", total: rows.sum(&:deductible_amount), count: rows.size }
        end
        by_category << { category: "減価償却費", total: depreciation_total, count: assets.size } if depreciation_total.positive?
        by_category = by_category.sort_by { |row| -row[:total] }

        income_by_month = (1..12).map { |m| incomes.select { |s| s.month == m }.sum { |s| s.total_override.to_i } }
        expense_by_month = (1..12).map { |m| expenses.select { |e| e.expense_date&.month == m }.sum(&:deductible_amount) }
        income_total = income_by_month.sum
        expense_total = by_category.sum { |row| row[:total] }

        {
          year: year,
          income_total: income_total,
          expense_total: expense_total,
          depreciation_total: depreciation_total,
          profit: income_total - expense_total,
          by_category: by_category,
          monthly: (1..12).map { |m| { month: m, income: income_by_month[m - 1], expense: expense_by_month[m - 1] } },
          expense_count: expenses.size,
          needs_review_count: expenses.count { |e| e.status == "needs_review" }
        }
      end

      # 科目別集計CSV: 青色申告決算書の経費欄へそのまま転記できる形
      def summary_csv(year)
        data = build_summary(year)
        CSV.generate do |csv|
          csv << [ "#{year}年 青色申告用 集計（#{current_user.display_name}）" ]
          csv << []
          csv << [ "売上（収入）合計", data[:income_total] ]
          csv << []
          csv << [ "勘定科目", "金額(円・家事按分後)", "件数" ]
          data[:by_category].each { |row| csv << [ row[:category], row[:total], row[:count] ] }
          csv << [ "経費合計", data[:expense_total], data[:expense_count] ]
          csv << []
          csv << [ "差引金額（売上-経費）", data[:profit] ]
          csv << []
          csv << [ "月", "売上", "経費" ]
          data[:monthly].each { |m| csv << [ "#{m[:month]}月", m[:income], m[:expense] ] }
        end
      end

      # 経費明細CSV: 日付/科目/店名/金額/按分/計上額/税率/取込元
      def details_csv(year)
        CSV.generate do |csv|
          csv << [ "日付", "勘定科目", "店名・支払先", "税込金額", "事業割合(%)", "計上額", "税率(%)", "メモ", "取込元" ]
          year_expenses(year).order(:expense_date).each do |e|
            csv << [ e.expense_date, e.account_category || "未分類", e.store_name, e.amount, e.business_ratio,
                     e.deductible_amount, e.tax_rate, e.memo, e.source == "csv" ? "明細CSV" : "レシート" ]
          end
        end
      end
    end
  end
end
