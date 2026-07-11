# business_expenses を複数選択して freee へ一括計上する。
# POST /api/v1/business_expenses/report_bulk_to_freee から呼ばれる。
# 対象は1件ずつ直列で処理し、成功/スキップ/失敗を振り分けて返す。
module Freee
  class BulkExpenseReporter
    Result = Struct.new(:succeeded, :skipped, :failed, keyword_init: true)

    # account_item_lookup / partner_lookup / report_sale_class はテスト時の差し替え用(DI)。
    # 省略時は実際の freee 連携サービスを使う。
    def initialize(user:, connection:, company_id: nil,
                    account_item_lookup: nil, partner_lookup: nil, report_sale_class: Freee::ReportSale)
      @user = user
      @conn = connection
      @company_id = (company_id || connection.company_id || ENV["FREEE_COMPANY_ID"]).to_s
      @account_item_lookup = account_item_lookup || Freee::AccountItemLookup.new(connection: connection, company_id: @company_id)
      @partner_lookup = partner_lookup || Freee::PartnerLookup.new(connection: connection, company_id: @company_id)
      @report_sale_class = report_sale_class
    end

    # ids: 対象の business_expense id 配列。current_user 所有分以外は黙って無視する。
    def call(ids)
      succeeded = []
      skipped = []
      failed = []

      @user.business_expenses.where(id: ids).find_each do |expense|
        outcome = report_one(expense)
        case outcome[:status]
        when :succeeded then succeeded << outcome[:payload]
        when :skipped   then skipped << outcome[:payload]
        else                 failed << outcome[:payload]
        end
      end

      Result.new(succeeded: succeeded, skipped: skipped, failed: failed)
    end

    private

    def report_one(expense)
      return { status: :skipped, payload: { id: expense.id, reason: "連携済み" } } if expense.freee_synced?

      if expense.account_category.blank?
        return { status: :failed, payload: { id: expense.id, reason: "勘定科目が未設定です。経費で科目を選択してください" } }
      end

      # freee に無い勘定科目は名寄せ(相互部分一致)で解決し、それでも無ければ新規作成する
      account_item_id = @account_item_lookup.find_or_create(name: expense.account_category)
      if account_item_id.nil?
        return { status: :failed, payload: { id: expense.id, reason: "勘定科目『#{expense.account_category}』をfreeeで解決/作成できませんでした" } }
      end

      # 取引先は「あれば紐づける」任意項目。経費は freee 上でも取引先なしで登録できるため、
      # 未解決(店名なし/freeeの取引先作成失敗)でも失敗にせず、取引先なしで計上する(店名は摘要に残る)。
      partner_id = expense.store_name.present? ? @partner_lookup.find_or_create(name: expense.store_name) : nil

      result = @report_sale_class.new(
        invoice: {
          total_amount: expense.amount,
          due_date: expense.expense_date.to_s,
          subject: "#{expense.store_name} #{expense.memo}".strip,
          category: nil,
          partner_id: partner_id
        },
        connection: @conn,
        company_id: @company_id,
        transaction_type: "expense",
        account_item_id: account_item_id,
        tax_rate: expense.tax_rate
      ).call

      if result.ok?
        expense.update!(freee_synced: true, freee_deal_id: result.deal_id)
        { status: :succeeded, payload: { id: expense.id, deal_id: result.deal_id } }
      else
        { status: :failed, payload: { id: expense.id, reason: result.error || "計上失敗" } }
      end
    rescue StandardError => e
      Rails.logger.warn("[Freee::BulkExpenseReporter#report_one] id=#{expense.id} #{e.class}: #{e.message}")
      { status: :failed, payload: { id: expense.id, reason: e.message } }
    end
  end
end
