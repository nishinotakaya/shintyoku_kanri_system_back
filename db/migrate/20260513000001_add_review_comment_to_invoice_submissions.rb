class AddReviewCommentToInvoiceSubmissions < ActiveRecord::Migration[8.0]
  def change
    add_column :invoice_submissions, :review_comment, :text
  end
end
