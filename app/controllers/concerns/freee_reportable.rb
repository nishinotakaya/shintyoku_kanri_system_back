# 4 つの controller (scanned_invoices / invoice_submissions / issued_invoice_pdfs / purchase_order_settings)
# で共通の「freee 計上 → record 更新 → JSON レスポンス」フローを 1 箇所にまとめた concern。
module FreeeReportable
  extend ActiveSupport::Concern

  private

  # @param record [#freee_deal_id, #freee_deal_id=, #freee_reported_at=, #update!]
  # @param invoice_payload [Hash] Freee::ReportSale#initialize の invoice: 引数
  # @param transaction_type [String] "income" / "expense"
  # @param account_item_id [Integer, nil] 経費の科目 (省略可)
  # @param success_message [String]
  def report_record_to_freee!(record:, invoice_payload:, transaction_type: "income", account_item_id: nil, success_message: "freee 計上完了")
    return render_freee_error("既に計上済 (deal_id=#{record.freee_deal_id})", status: :unprocessable_entity) if record.freee_deal_id.present?

    conn = current_user.freee_connection
    return render_freee_error("freee 未接続", status: :bad_request) unless conn&.identity

    return render_freee_error("freee 再ログイン失敗", status: :bad_request) unless refresh_freee_session!(conn)

    result = Freee::ReportSale.new(
      invoice: invoice_payload,
      connection: conn,
      company_id: ENV["FREEE_COMPANY_ID"],
      transaction_type: transaction_type,
      account_item_id: account_item_id
    ).call

    if result.ok?
      record.update!(freee_deal_id: result.deal_id, freee_reported_at: Time.current)
      extra = block_given? ? (yield record, result) || {} : {}
      render json: { success: true, deal_id: result.deal_id, message: success_message }.merge(extra)
    else
      render json: { success: false, error: result.error || "計上失敗 (status=#{result.status})", body: result.body&.slice(0, 200) }, status: :bad_request
    end
  end

  # cookie が 10 分以内なら use、それ以外は再ログイン。
  # (freee セッションは別ログイン等で12時間より早く無効化されることがあり、
  #  古い cookie のまま進めると内部APIが一律401になるため、ほぼ毎回取り直す)
  def refresh_freee_session!(conn)
    return true if conn.session_cookie.present? && conn.last_connected_at && conn.last_connected_at >= 10.minutes.ago
    login = Freee::SessionLogin.new(identity: conn.identity, password: conn.password_encrypted).call
    return false unless login.ok?
    conn.update!(
      session_cookie: login.session_cookie,
      csrf_token: login.csrf_token,
      company_id: login.company_id.presence || conn.company_id,
      last_connected_at: Time.current,
      last_status_code: login.status,
      status: "connected"
    )
    true
  end

  def render_freee_error(message, status: :bad_request)
    render json: { error: message }, status: status
  end
end
