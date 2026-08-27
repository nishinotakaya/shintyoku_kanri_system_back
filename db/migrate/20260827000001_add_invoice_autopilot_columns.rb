class AddInvoiceAutopilotColumns < ActiveRecord::Migration[8.0]
  def change
    # 統合請求書(ラボップ宛)でこの人の稼働に適用する時給。
    # 支払側の時給(注文書 rate_per_hour や unit_price)とは別レート
    # (例: 川村さん wings は支払 2,875円/請求 3,500円)。admin が設定する。
    add_column :invoice_settings, :merged_unit_price, :integer

    # 月次自動生成(InvoiceAutoGenerator)が管理している申請フラグ。
    # true の間は毎日の勤怠時間から total_override を再計算する。
    # ユーザーが金額や明細を手で編集したら false に落として以後触らない。
    add_column :invoice_submissions, :auto_synced, :boolean, default: false, null: false
  end
end
