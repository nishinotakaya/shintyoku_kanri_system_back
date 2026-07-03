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

      # GET /api/v1/tax_reports/export_pdf?year=2026&deduction=650000
      # 青色申告決算書(損益計算書)の様式風PDF（転記・保管用）
      def export_pdf
        year = target_year
        deduction = params[:deduction].presence&.to_i || 650_000
        path = TaxReturnPdfRenderer.new(current_user, year: year, deduction: deduction).call
        send_file path, type: "application/pdf", filename: "青色申告決算書_#{year}年分.pdf", disposition: "attachment"
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
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

      def build_summary(year)
        TaxSummaryBuilder.call(current_user, year)
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
