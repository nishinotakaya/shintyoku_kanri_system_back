class AddCategoryToWorkReports < ActiveRecord::Migration[8.0]
  def change
    add_column :work_reports, :category, :string
  end
end
