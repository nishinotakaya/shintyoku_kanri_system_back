class CreateGitPrNotes < ActiveRecord::Migration[8.0]
  def change
    create_table :git_pr_notes do |t|
      t.integer :user_id, null: false
      t.string :project_key, null: false
      t.string :repo_name, null: false
      t.integer :pr_number, null: false
      t.text :content, null: false
      t.timestamps
    end
    add_index :git_pr_notes, [ :project_key, :repo_name, :pr_number ]
  end
end
