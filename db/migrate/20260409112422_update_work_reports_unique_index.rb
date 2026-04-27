class UpdateWorkReportsUniqueIndex < ActiveRecord::Migration[8.0]
  def change
    remove_index :work_reports, [ :user_id, :work_date ]
    add_index :work_reports, [ :user_id, :work_date, :category ], unique: true
  end
end
