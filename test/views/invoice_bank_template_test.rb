require "test_helper"

# 請求書PDFテンプレートの「お振込先」は、対象ユーザー(setting=請求者/受領者)の口座を出すこと。
# admin(西野)が代理発行しても操作者(発行者=_issuer_setting)の口座を出してはならない。
class InvoiceBankTemplateTest < Minitest::Test
  ERB_PATH = Rails.root.join("app/views/invoices/invoice.html.erb")

  def bank_block
    src = File.read(ERB_PATH)
    # 「お振込先：」直後の出力行を取り出す
    src[/お振込先：.*?<div>(.*?)<\/div>/m, 1].to_s
  end

  def test_bank_uses_subject_setting
    assert_includes bank_block, "setting.bank_info",
      "振込先が setting.bank_info(対象ユーザーの口座)を使っていない"
  end

  def test_bank_does_not_use_issuer_setting
    refute_includes bank_block, "_issuer_setting.bank_info",
      "振込先が _issuer_setting.bank_info(発行者=西野の口座)を使っている(再発)"
  end
end
