class CreateWorkReportExpensePhotos < ActiveRecord::Migration[8.0]
  def change
    # 稼働報告書(運送)の実費レシート写真。1日報につき複数枚。
    # 一覧APIでバイナリを読まないよう work_reports 本体とはテーブルを分ける(メーター写真と同じ方針)
    create_table :work_report_expense_photos do |t|
      t.references :work_report, null: false, foreign_key: true
      t.string :content_type, null: false
      t.binary :data, null: false
      t.integer :amount
      t.string :label
      t.timestamps
    end
  end
end
