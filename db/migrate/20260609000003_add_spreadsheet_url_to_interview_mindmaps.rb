class AddSpreadsheetUrlToInterviewMindmaps < ActiveRecord::Migration[8.0]
  def change
    add_column :interview_mindmaps, :spreadsheet_url, :string # 書き出し先スプレッドシートURL
  end
end
