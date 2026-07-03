require "test_helper"

# 印鑑(ハンコ)は「請求書/立替金=請求者(対象ユーザー=user)」「支払通知書=発行者」の印鑑を使い、
# まず DB(users.seal_image)を優先、無ければ従来の public/hanko_* にフォールバックすること。
class InvoiceSealTemplateTest < Minitest::Test
  def erb(name)
    File.read(Rails.root.join("app/views/invoices/#{name}"))
  end

  def test_invoice_seal_user_is_subject_for_invoice
    src = erb("invoice.html.erb")
    assert_includes src, '_seal_user    = _is_payment_notice ? _issuer_user : user',
      "請求書の印鑑が請求者(user)になっていない"
  end

  def test_invoice_prefers_db_seal_then_file_fallback
    %w[invoice.html.erb expense.html.erb expense_invoice.html.erb purchase_order.html.erb].each do |f|
      src = erb(f)
      assert_includes src, "seal_image", "#{f}: DB の seal_image を参照していない"
      assert_includes src, "hanko_src = _db_seal.present? ? _db_seal : _file_seal",
        "#{f}: DB印鑑優先→ファイルfallback になっていない"
    end
  end
end
