# 稼働報告(カレンダー)の実費レシート1枚につき立替金1件を自動作成するための紐付け。
# 自動作成行と手入力行を確実に区別できるようにして、同期時の誤削除を防ぐ。
class AddWorkReportExpensePhotoToExpenses < ActiveRecord::Migration[8.0]
  def change
    add_column :expenses, :work_report_expense_photo_id, :integer
    add_index :expenses, :work_report_expense_photo_id,
              unique: true,
              where: "work_report_expense_photo_id IS NOT NULL",
              name: "index_expenses_on_work_report_expense_photo_id"
  end
end
