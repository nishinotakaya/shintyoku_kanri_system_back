class AddProgressSheetUrlToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :progress_sheet_url, :string
  end
end
