# 統合請求書の明細を組み立てる単一窓口。
# 各申請の「確定額そのまま」を使い、元申請(invoice_submissions)は一切書き換えない。
#   - items_override があればその行（氏名 prefix 付き）
#   - 無ければ確定額(税抜)を1行に集約
module MergedInvoiceItems
  module_function

  # submissions: InvoiceSubmission の配列（admin 先頭で並べ替え済み想定）
  # 戻り値: [{ label:, qty:, unit:, unit_price:, amount: }, ...]
  def build(submissions)
    submissions.flat_map { |submission| for_submission(submission) }
  end

  def for_submission(submission)
    name = submission.user.display_name.to_s.strip
    prefix = name.empty? ? "" : "#{name} "
    if submission.items_override.present?
      return submission.items_override.map do |it|
        h = it.respond_to?(:to_h) ? it.to_h : it
        label = (h["label"] || h[:label]).to_s
        label = "#{prefix}#{label}" unless prefix.empty? || label.start_with?(prefix)
        { label: label, qty: (h["qty"] || h[:qty]).to_f, unit: ((h["unit"] || h[:unit]).to_s.presence || "式"),
          unit_price: (h["unit_price"] || h[:unit_price]).to_i, amount: (h["amount"] || h[:amount]).to_i }
      end
    end
    tax_rate = InvoiceSetting.defaults_for(submission.category)[:tax_rate].to_i
    subtotal = submission.total_override.to_i
    subtotal = (subtotal / (1.0 + tax_rate / 100.0)).round if tax_rate > 0

    # タマ(wings)と同じく「◯◯業務(N.0hまで) N 時間 単価」の時間表記で出す（リビング等も共通）。
    # 稼働時間は業務報告書(work_reports)から取得し、単価は 確定額(税抜)÷時間 で逆算＝金額は変えない。
    # 稼働が無い/金額が時間で割り切れないときだけ、従来どおり「1式」にフォールバック。
    setting = submission.user.invoice_setting_for(submission.category)
    hours = worked_hours_for(submission)
    if hours.positive? && subtotal.positive? && (subtotal % hours).zero?
      item_label = submission.item_label_override.presence || setting.item_label.presence || "開発支援業務"
      return [ { label: "#{prefix}#{item_label}(#{format('%.1f', hours)}hまで)",
                 qty: hours, unit: "時間", unit_price: subtotal / hours, amount: subtotal } ]
    end

    label = "#{prefix}#{submission.subject_override.presence || submission.item_label_override.presence || setting.item_label}"
    [ { label: label, qty: 1, unit: "式", unit_price: subtotal, amount: subtotal } ]
  end

  # 申請ユーザーのその月・カテゴリの稼働時間(業務報告書)。整数時間に丸めて返す（0=取得不可）。
  def worked_hours_for(submission)
    user = submission.user
    period = user.period_for(submission.year, submission.month)
    user.work_reports.in_range(period).by_category(submission.category).sum(:hours).to_f.round
  rescue
    0
  end

  # admin(西野) を先頭に並べた順序で submissions を返す
  def order(submissions)
    submissions.to_a.sort_by { |s| [ s.user.admin? ? 0 : 1, s.user.display_name.to_s, s.category.to_s ] }
  end

  # 任意フォーマットの items(ハッシュ/StrongParams) を正規化
  def normalize(raw)
    return nil unless raw.is_a?(Array) && raw.any?
    items = raw.map do |it|
      h = it.respond_to?(:to_unsafe_h) ? it.to_unsafe_h : it.to_h
      qty = (h["qty"] || h[:qty]).to_f
      unit_price = (h["unit_price"] || h[:unit_price]).to_i
      amount = (h["amount"] || h[:amount]).present? ? (h["amount"] || h[:amount]).to_i : (qty * unit_price).round
      { "label" => (h["label"] || h[:label]).to_s, "qty" => qty, "unit" => ((h["unit"] || h[:unit]).to_s.presence || "式"),
        "unit_price" => unit_price, "amount" => amount }
    end
    items.reject { |it| it["label"].blank? && it["amount"].zero? }.presence
  end
end
