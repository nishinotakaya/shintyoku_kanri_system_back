class AddSubcontractFromToUsers < ActiveRecord::Migration[8.0]
  # 対象パートナーの承認済み請求(この年月分以降)を admin の売上に合算し、
  # 同額を「外注工賃」として経費計上する開始月。null=合算対象外。
  def change
    add_column :users, :subcontract_from, :date

    # 既存運用: 川村さんは2026年4月分〜、須崎さんは2026年6月分〜(初回請求月)
    reversible do |dir|
      dir.up do
        execute("UPDATE users SET subcontract_from = '2026-04-01' WHERE display_name LIKE '%川村%'")
        execute("UPDATE users SET subcontract_from = '2026-06-01' WHERE display_name LIKE '%須崎%'")
      end
    end
  end
end
