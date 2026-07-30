# 統合請求書の明細を組み立てる単一窓口。
# 元申請(invoice_submissions)は一切書き換えない。
#   - items_override があればその行（氏名 prefix 付き）
#   - 無ければ個別請求書とまったく同じ明細（注文書の時給 + 控除行など）を氏名 prefix 付きで使う
#   - それも取れないときだけ確定額(税抜)を1行に集約
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
    # 個別請求書とまったく同じ明細（注文書の時給 × 稼働時間 + シェアラウンジ等の控除行）を使う。
    # 以前は「確定額(税抜) ÷ 稼働時間」で単価を逆算していたため、控除行が単価に溶けて
    # 統合すると時給が下がって見えていた（例: 西野 3,750円/h → 3,310円/h）。
    # 統合の請求金額そのものは confirmed_total で各申請の確定額に固定するので、ここは表示明細に徹する。
    items = invoice_items_for(submission, prefix)
    return items if items.present?

    # 時給が引けないカテゴリ(resystems 等)や稼働 0 のときだけ、確定額(税抜)を1式に集約する。
    setting = submission.user.invoice_setting_for(submission.category)
    label = "#{prefix}#{submission.subject_override.presence || submission.item_label_override.presence || setting.item_label}"
    subtotal = subtotal_of(submission)
    [ { label: label, qty: 1, unit: "式", unit_price: subtotal, amount: subtotal } ]
  end

  # 個別請求書(InvoicePdfRenderer)がその申請ぶんに出す明細を、氏名 prefix 付きで返す。
  # 統合でも個別でも同じ単価・同じ行になるよう、明細生成の実装は 1 箇所に寄せる。
  def invoice_items_for(submission, prefix)
    renderer = InvoicePdfRenderer.new(
      submission.user,
      year: submission.year, month: submission.month, category: submission.category,
      item_label_override: submission.item_label_override,
      subject_override: submission.subject_override
    )
    Array(renderer.calculation[:items]).map do |item|
      label = item[:label].to_s
      label = "#{prefix}#{label}" unless prefix.empty? || label.start_with?(prefix)
      item.merge(label: label)
    end
  rescue StandardError
    []
  end

  # 統合請求書の請求金額(税込)。個別請求書の確定額の単純合計と必ず一致させる。
  def confirmed_total(submissions)
    submissions.sum { |submission| confirmed_total_for(submission) }
  end

  def confirmed_total_for(submission)
    return submission.total_override.to_i if submission.total_override.present?
    tax_rate = InvoiceSetting.defaults_for(submission.category)[:tax_rate].to_i
    subtotal = for_submission(submission).sum { |item| item[:amount].to_i }
    subtotal + (subtotal * tax_rate / 100.0).round
  end

  # 申請の確定額(税抜)。total_override は税込なので税率で割り戻す。
  def subtotal_of(submission)
    tax_rate = InvoiceSetting.defaults_for(submission.category)[:tax_rate].to_i
    subtotal = submission.total_override.to_i
    tax_rate > 0 ? (subtotal / (1.0 + tax_rate / 100.0)).round : subtotal
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
