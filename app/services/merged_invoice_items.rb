# 統合請求書の明細を組み立てる単一窓口。
# 元申請(invoice_submissions)は一切書き換えない。
#   - items_override があればその行（氏名 prefix 付き）
#   - 無ければ個別請求書とまったく同じ明細（注文書の時給 + 控除行など）を氏名 prefix 付きで使う
#   - それも取れない（明細合計が0円）ときだけ確定額(税抜)を1行に集約
#   - total_override(確定額)がある申請は、明細合計とのズレを「調整額」行で埋め、明細合計 == 小計 を必ず成立させる
#     （total_override が無い申請は確定額という概念自体が無いので調整行は入れない。明細合計がそのまま請求額になる）
module MergedInvoiceItems
  module_function

  # submissions: InvoiceSubmission の配列（admin 先頭で並べ替え済み想定）
  # 戻り値: [{ label:, qty:, unit:, unit_price:, amount: }, ...]
  def build(submissions)
    submissions.flat_map { |submission| for_submission(submission) }
  end

  # ============ 統合時給モード（月次自動生成用） ============
  # ラボップへの統合請求は「人ごとに決めた請求時給 × 稼働時間」で組む。
  # 支払側の申請(total_override=注文書レート)とは金額が独立する
  # (例: 川村さん wings は支払 2,875円/h・請求 3,500円/h)。
  # 時給は InvoiceSetting.billing_unit_price_for(user, category) が解決する。
  def build_billed(submissions)
    submissions.flat_map { |submission| billed_items_for(submission) }
  end

  # 統合請求の税込合計。明細合計(税抜)＋税で組む（申請の確定額は使わない）。
  def billed_total(submissions)
    return 0 if submissions.empty?
    tax_rate = InvoiceSetting.defaults_for(submissions.first.category)[:tax_rate].to_i
    subtotal = build_billed(submissions).sum { |item| item[:amount].to_i }
    subtotal + (subtotal * tax_rate / 100.0).round
  end

  def billed_items_for(submission)
    name = submission.user.display_name.to_s.strip
    prefix = name.empty? ? "" : "#{name} "
    # 手編集した明細は統合時給よりも優先する（明示的な上書き）
    return for_submission(submission) if submission.items_override.present?

    rate = InvoiceSetting.billing_unit_price_for(submission.user, submission.category)
    hours = billed_hours_for(submission)
    # 時給が引けないカテゴリや稼働 0 は従来ロジック(確定額ベース)に落とす
    return for_submission(submission) if rate.zero? || hours.zero?

    setting = submission.user.invoice_setting_for(submission.category)
    quantity = hours == hours.to_i ? hours.to_i : hours.round(1)
    items = [ {
      label: "#{prefix}#{setting.item_label}(#{format('%.1f', hours)}hまで)",
      qty: quantity, unit: "時間", unit_price: rate, amount: (hours * rate).round
    } ]
    # シェアラウンジ利用料などの固定行(控除含む)は統合請求にもそのまま載せる
    Array(setting.default_items).each do |it|
      qty = (it["qty"] || it[:qty] || 1).to_f
      price = (it["price"] || it[:price] || 0).to_i
      label = (it["label"] || it[:label]).to_s
      label = "#{prefix}#{label}" unless prefix.empty? || label.start_with?(prefix)
      items << { label: label, qty: qty, unit: (it["unit"] || it[:unit]).to_s.presence || "式",
                 unit_price: price, amount: (qty * price).round }
    end
    items
  end

  # 統合請求の稼働時間（個別請求書と同じ範囲: billing period × カテゴリ）
  def billed_hours_for(submission)
    period = submission.user.period_for(submission.year, submission.month)
    scope = submission.user.work_reports.in_range(period)
    scope = scope.by_category(submission.category) if submission.category.present?
    scope.sum(:hours).to_f
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
    items = invoice_items_for(submission, prefix)
    items_amount_sum = items.sum { |item| item[:amount].to_i }

    # 時給が引けないカテゴリ(resystems 等)や稼働 0 のときは明細行の合計が 0 円になる
    # （＝行が確定額を何も説明できていない）。この場合だけ確定額(税抜)を1式に集約する。
    return lump_sum_item(submission, prefix) if items_amount_sum.zero?

    # 明細合計と確定額(税抜)がズレていれば調整行を足し、「明細合計 == 小計」を必ず成立させる。
    # 統合請求書の小計・合計は confirmed_total 経由で各申請の確定額(total_override)から作られるため、
    # 放置すると明細合計と小計が食い違うインボイスが客先に出てしまう。
    # total_override が無い申請は確定額そのものが存在しない（confirmed_total_for が明細合計から
    # 逆に請求額を算出する）ので、ここで調整行を足すと明細合計を 0 円に打ち消してしまう。対象外にする。
    if submission.total_override.present?
      confirmed_subtotal = subtotal_of(submission)
      adjustment = confirmed_subtotal - items_amount_sum
      items << { label: "調整額", qty: 1, unit: "式", unit_price: adjustment, amount: adjustment } unless adjustment.zero?
    end
    items
  end

  # 明細行が確定額を説明できないとき（0円行のみ／稼働なしで行が作れない）に使う、
  # 確定額(税抜)を1式に集約したフォールバック行。
  def lump_sum_item(submission, prefix)
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
  rescue StandardError => error
    # 明細生成に失敗しても、確定額の1式フォールバックで請求書自体は出す（金額の違う請求書を
    # 無言で出さないため、原因はログに残す）。for_submission 側の items_amount_sum.zero? が
    # 空配列を検知して lump_sum_item に落とす。
    Rails.logger.error(
      "[MergedInvoiceItems] 明細生成に失敗 submission_id=#{submission.id} " \
      "user_id=#{submission.user_id}: #{error.class}: #{error.message}"
    )
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
