# 請求書の月次自動運転。毎日1回 cron (GitHub Actions) から実行される想定で、全処理が冪等。
#   ① 当月分(締め日ベースの billing period が今日を含む月)の請求書申請を全員分 draft で自動作成
#      — 対象: その期間に勤怠時間があるカテゴリ + 前月に請求書申請があったカテゴリ(稼働入力前でも行を出す)
#   ② 自動作成した draft (auto_synced=true) の請求額を、その日までの勤怠時間から毎日再計算
#      — 金額や明細を手で編集した申請(auto_synced=false)には触らない
#   ③ 締めが過ぎた前月分は、申請を admin 承認 → ラボップ宛の統合請求書PDFを自動生成・保存
#      — 明細は「統合時給(InvoiceSetting.billing_unit_price_for) × 稼働時間 + 固定行」
#      — 同月・同カテゴリの統合PDFが既にあれば何もしない(手動発行とも共存)
#
# 手動実行: fly ssh console -a shintyoku-app -C "/rails/bin/rails runner 'InvoiceAutoGenerator.run'"
class InvoiceAutoGenerator
  MERGED_CATEGORIES = %w[wings living].freeze

  Result = Struct.new(:created, :refreshed, :approved, :pdfs, keyword_init: true)

  def self.run(today: Date.current)
    new(today: today).run
  end

  def initialize(today: Date.current)
    @today = today
    @admin = User.order(:id).detect(&:admin?)
    raise "admin ユーザーが見つかりません" unless @admin
  end

  def run
    year, month = current_billing_month
    created = ensure_current_month_submissions(year, month)
    refreshed = refresh_auto_synced_totals(year, month)
    approved, pdfs = finalize_previous_month(year, month)
    result = Result.new(created: created, refreshed: refreshed, approved: approved, pdfs: pdfs)
    Rails.logger.info("[InvoiceAutoGenerator] #{year}/#{month} " \
                      "created=#{created.size} refreshed=#{refreshed.size} " \
                      "approved=#{approved.size} pdfs=#{pdfs.map { |p| p[:filename] }}")
    result
  end

  private

  # 「今月」= admin の締め日設定で今日を含む billing period の月(26日始まりなら 8/26〜9/25 が 9月分)
  def current_billing_month
    base = @today
    [ [ base.year, base.month ], next_month(base), prev_month(base) ].each do |year, month|
      period = @admin.period_for(year, month)
      return [ year, month ] if period.cover?(@today)
    end
    [ base.year, base.month ]
  end

  def next_month(date) = [ date.next_month.year, date.next_month.month ]
  def prev_month(date) = [ date.prev_month.year, date.prev_month.month ]

  # ① 当月分の draft を全員分そろえる
  def ensure_current_month_submissions(year, month)
    created = []
    User.find_each do |user|
      target_categories_for(user, year, month).each do |category|
        exists = InvoiceSubmission.exists?(
          user_id: user.id, year: year, month: month, category: category, kind: "invoice"
        )
        next if exists

        record = InvoiceSubmission.create!(
          user: user, year: year, month: month, category: category, kind: "invoice",
          status: "draft", auto_synced: true,
          total_override: auto_total_for(user, year, month, category)
        )
        created << record
      end
    end
    created
  end

  # 自動作成するカテゴリ: 当期間に勤怠があるもの + 前月に請求書申請があったもの
  # (月初はまだ勤怠 0 でも、毎月請求しているカテゴリは行を出して毎日反映していく)
  def target_categories_for(user, year, month)
    period = user.period_for(year, month)
    with_hours = user.work_reports.in_range(period)
                     .group(:category).sum(:hours)
                     .select { |category, hours| category.present? && hours.to_f.positive? }
                     .keys
    prev_year, prev_mon = prev_month(Date.new(year, month, 1))
    recurring = InvoiceSubmission.where(user_id: user.id, kind: "invoice",
                                        year: prev_year, month: prev_mon)
                                 .where.not(category: nil).distinct.pluck(:category)
    (with_hours + recurring).uniq & InvoiceSetting::CATEGORY_LABELS.keys
  end

  # ② auto_synced な draft の請求額をその日までの勤怠から再計算
  def refresh_auto_synced_totals(year, month)
    refreshed = []
    InvoiceSubmission.where(year: year, month: month, kind: "invoice",
                            status: "draft", auto_synced: true).find_each do |record|
      next if record.items_override.present? # 手入力明細があるものは触らない(保険)
      total = auto_total_for(record.user, year, month, record.category)
      next if record.total_override.to_i == total.to_i
      record.update!(total_override: total)
      refreshed << record
    end
    refreshed
  end

  # 申請の税込合計(既存の作成フローと同じ計算: InvoicePdfRenderer.calculation)
  def auto_total_for(user, year, month, category)
    InvoicePdfRenderer.new(user, year: year, month: month, category: category).calculation[:total].to_i
  rescue StandardError => e
    Rails.logger.warn("[InvoiceAutoGenerator] auto_total失敗 user=#{user.id} #{category}: #{e.class}: #{e.message}")
    nil
  end

  # ③ 締めが過ぎた前月分: 承認 → 統合PDF生成
  def finalize_previous_month(current_year, current_month)
    prev_year, prev_mon = prev_month(Date.new(current_year, current_month, 1))
    period = @admin.period_for(prev_year, prev_mon)
    return [ [], [] ] unless period.last < @today # 締め前は何もしない(保険)

    approved = approve_pending_submissions(prev_year, prev_mon)
    pdfs = MERGED_CATEGORIES.filter_map { |category| publish_merged_pdf(prev_year, prev_mon, category) }
    [ approved, pdfs ]
  end

  # 前月分の draft/pending 請求書申請を admin として承認する
  def approve_pending_submissions(year, month)
    approved = []
    InvoiceSubmission.where(year: year, month: month, kind: "invoice", status: %w[draft pending])
                     .find_each do |record|
      record.update!(status: "approved", reviewer_id: @admin.id, reviewed_at: Time.current)
      approved << record
    end
    approved
  end

  # ラボップ宛の統合請求書PDFを保存する(既に同月・同カテゴリの統合PDFがあればスキップ)
  def publish_merged_pdf(year, month, category)
    return nil if IssuedInvoicePdf.exists?(year: year, month: month, category: category,
                                           kind: "invoice", file_format: "pdf")

    subs = InvoiceSubmission.where(year: year, month: month, category: category,
                                   kind: "invoice", status: "approved").includes(:user).to_a
    return nil if subs.empty?

    ordered = MergedInvoiceItems.order(subs)
    items = MergedInvoiceItems.build_billed(ordered)
    return nil if items.sum { |item| item[:amount].to_i }.zero?

    primary = ordered.first
    renderer = InvoicePdfRenderer.new(
      primary.user,
      year: year, month: month, category: category,
      client_name_override: I18n.t("companies.labop.name"),
      issuer_user_override: @admin,
      items_override: items,
      note: primary.note
    )
    path = renderer.call

    users_sorted = User.admin_first(ordered.map(&:user).uniq)
    surnames = users_sorted.map { |u| u.display_name.to_s.split(/[\s　]/).first }
                           .compact.reject(&:empty?).uniq.join("_")
    cat_label = InvoiceSetting::CATEGORY_LABELS[category] || category
    filename = "#{cat_label}_#{surnames.presence || '集約'}_請求書_#{year}年_#{month}月分.pdf"

    record = IssuedInvoicePdf.create!(
      user: @admin, kind: "invoice", file_format: "pdf",
      year: year, month: month, category: category,
      source_submission_ids: ordered.map(&:id),
      merged: ordered.size > 1,
      total_amount: renderer.calculation[:total],
      filename: filename,
      file_data: File.binread(path),
      items_override: items,
      generated_at: Time.current
    )
    { filename: filename, id: record.id, total: record.total_amount }
  end
end
