class AddTransportColumnsToWorkReports < ActiveRecord::Migration[8.0]
  def change
    # 運送業(category=transport)向けの日報項目。他カテゴリでは未使用のまま null で残る。
    add_column :work_reports, :distance_km, :decimal, precision: 8, scale: 1      # 走行距離km
    add_column :work_reports, :delivery_count, :integer                          # 配送件数
    add_column :work_reports, :meter_start, :integer                             # 開始メーター
    add_column :work_reports, :meter_end, :integer                               # 終了メーター
    add_column :work_reports, :note, :text                                       # 備考欄(content=配送内容とは別)
    add_column :work_reports, :weekly_payment, :boolean, default: false, null: false # 週払かどうか

    # 検印(本人 or admin が押す確認印)。押した日時と押した人を記録する。
    add_column :work_reports, :approved_at, :datetime
    add_column :work_reports, :approved_by_id, :integer

    add_index :work_reports, :approved_by_id
    add_foreign_key :work_reports, :users, column: :approved_by_id
  end
end
