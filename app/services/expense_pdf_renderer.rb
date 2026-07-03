require "open3"
require "fileutils"
require "erb"

# 立替金の請求書 PDF を生成。
# 原本: 立替金202603010331 (1).pdf と同じフォーマット。
# 交通費を区間ごとにまとめて「交通費_往復(六実駅〜品川駅) 8回 1,578 12,624」形式。
class ExpensePdfRenderer
  TEMPLATE = Rails.root.join("app/views/invoices/expense_invoice.html.erb")
  SCRIPT   = Rails.root.join("lib/exporters/html_to_pdf.mjs")

  def initialize(user, year:, month:, application_date: nil, category: nil,
                 client_name_override: nil, issuer_user_override: nil,
                 merged_users: nil, mode: :positive, title_override: nil)
    @user = user
    @year = year
    @month = month
    @application_date = application_date
    @category = category.presence
    @client_name_override = client_name_override.presence
    @issuer_user = issuer_user_override || user
    # 立替金集約モード: @user に加えて他ユーザーの expense もまとめる（案 A 通常立替金 1 通用）
    @merged_users = Array(merged_users).reject { |u| u.id == user.id }
    # mode:
    #   :positive (default) → amount > 0 の expense（通常立替金）
    #   :negative → amount < 0 の expense（シェアラウンジ相殺など）
    @mode = mode.to_sym
    # 支払通知書モードで使う: H1 タイトルを「支払通知書」等に差替
    @title_override = title_override.to_s.presence
  end

  def call
    period = @user.period_for(@year, @month)
    # 申請日: 発行者(issuer)の monthly_settings を優先（西野が川村の立替金 PDF を発行する場合は西野の末日設定）
    application_date = @application_date || @issuer_user.application_date_for(@year, @month) || @user.application_date_for(@year, @month)
    setting = @user.invoice_setting_for(@category || "wings")
    issuer_setting = @issuer_user.invoice_setting_for(@category || "wings")
    issuer_user = @issuer_user
    # 宛先 (client_name) と敬称 (honorific) の決定: InvoicePdfRenderer と同じ規則
    labop_name = I18n.t("companies.labop.name")
    labop_forwarding_initial = @issuer_user && @issuer_user != @user
    if @client_name_override.present?
      client_name = @client_name_override
      honorific = (client_name == labop_name) ? "御中" : "様"
    elsif !labop_forwarding_initial
      client_name = @user.invoice_recipient_name
      honorific = @user.invoice_recipient_honorific
    else
      client_name = setting.client_name
      honorific = setting.honorific.presence || "御中"
    end
    # 集約モード: @user に加え @merged_users の expense も取り込む（複数ユーザー 1 通の通常立替金）
    target_users = [ @user, *@merged_users ].uniq
    user_expense_pairs = []
    target_users.each do |u|
      u_period = u.period_for(@year, @month)
      u_scope = u.expenses.billed_in(format("%04d-%02d", @year, @month), u_period)
      u_scope = u_scope.where(category: @category) if @category
      u_scope = u_scope.where(company_burden: true) # 会社負担対象のみ
      # 通常モード: 正額のみ / 相殺モード: 負額のみ
      u_scope = (@mode == :negative) ? u_scope.where("amount < 0") : u_scope.where("amount > 0")
      u_scope.each { |e| user_expense_pairs << [ u, e ] }
    end
    expenses = user_expense_pairs.map { |(_, e)| e } # 後段の subtotal 計算等で使用

    # 区間ごとにグルーピング
    # 「発行者≠申請者」の labop モード or 複数ユーザー集約時は、ラベル先頭に申請者氏名を付ける
    labop_forwarding = @issuer_user && @issuer_user != @user
    multi_user = target_users.size > 1
    should_prefix_name = labop_forwarding || multi_user
    # グルーピングキー:
    # - 駅情報があるもの: [user_id, "from-to"] でまとめる（同じ区間の往復を 1 行に集約）
    # - 駅情報がない（purpose 主体: シェアラウンジ等）: [user_id, expense_id] で 1 件 1 行（金額の異なるレコードを混ぜない）
    grouped_pairs = user_expense_pairs.group_by { |(u, e)|
      if e.from_station.to_s.strip.present? || e.to_station.to_s.strip.present?
        [ u.id, "#{e.from_station}-#{e.to_station}" ]
      else
        [ u.id, "purpose-#{e.id}" ]
      end
    }
    items = grouped_pairs.map do |(_uid, route_key), pairs|
      grp_user, _ = pairs.first
      grp_exps = pairs.map { |(_, e)| e }
      unit_price = grp_exps.first.amount
      qty = grp_exps.size
      surname = grp_user.display_name.to_s.split(/[\s　]/).first.to_s
      prefix = (should_prefix_name && !surname.empty?) ? "#{surname} " : ""
      label = if route_key.to_s.start_with?("purpose-")
                "#{prefix}#{grp_exps.first.purpose.to_s}"
              else
                route = "#{grp_exps.first.from_station}-#{grp_exps.first.to_station}"
                "#{prefix}#{route}"
              end
      {
        label: label,
        qty: qty,
        unit: "回",
        unit_price: unit_price,
        amount: unit_price * qty
      }
    end

    subtotal = items.sum { |i| i[:amount] }
    total = subtotal # 税込み金額なので消費税行なし

    issue_date = period.last
    # 発行者(issuer)の設定を優先（西野が川村の立替金 PDF を発行する場合は西野の設定）
    due_date = calc_due_date(issue_date, issuer_setting || setting)
    invoice_no = "#{issue_date.strftime('%Y%m%d')}#{format('%04d', @user.id)}"

    user = @user
    title_text = @title_override || "請求書"
    data = { items: items, subtotal: subtotal, total: total,
             issue_date: issue_date, due_date: due_date, invoice_no: invoice_no,
             application_date: application_date, title_text: title_text }

    html_body = ERB.new(File.read(TEMPLATE)).result(binding)

    out_dir = Rails.root.join("tmp/exports")
    FileUtils.mkdir_p(out_dir)
    html_path = out_dir.join("expense_inv_#{user.id}_#{@year}_#{@month}_#{SecureRandom.hex(4)}.html").to_s
    pdf_path  = html_path.sub(/\.html$/, ".pdf")
    File.write(html_path, html_body)

    out, err, status = Open3.capture3("node", SCRIPT.to_s, html_path, pdf_path)
    raise "html_to_pdf failed: #{err}" unless status.success?
    pdf_path
  ensure
    File.delete(html_path) if defined?(html_path) && html_path && File.exist?(html_path)
  end

  private

  def calc_due_date(issue_date, setting)
    case setting.payment_due_type
    when "next_month_end"
      m = issue_date >> 1; Date.new(m.year, m.month, -1)
    when "next_next_month_end"
      m = issue_date >> 2; Date.new(m.year, m.month, -1)
    when "month_end"
      Date.new(issue_date.year, issue_date.month, -1)
    when /\Adays_(\d+)\z/
      issue_date + $1.to_i
    else
      # デフォルトは翌月末日 (payment_due_days が指定されていればそれを優先)
      if setting.respond_to?(:payment_due_days) && setting.payment_due_days.present?
        issue_date + setting.payment_due_days
      else
        m = issue_date >> 1; Date.new(m.year, m.month, -1)
      end
    end
  end
end
