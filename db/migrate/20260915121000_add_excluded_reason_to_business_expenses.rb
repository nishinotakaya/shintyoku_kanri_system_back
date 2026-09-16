# 経費を「対象外」(status=excluded) にしたときの理由。行を消さずに集計から外すことで、
# freee 再取込での復活(import_hash が無いと再作成される)を防ぎ、除外した根拠も残す。
class AddExcludedReasonToBusinessExpenses < ActiveRecord::Migration[8.0]
  def change
    add_column :business_expenses, :excluded_reason, :string
  end
end
