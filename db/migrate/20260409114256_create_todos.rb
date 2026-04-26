class CreateTodos < ActiveRecord::Migration[8.0]
  def change
    create_table :todos do |t|
      t.references :user, null: false, foreign_key: true
      t.string :title
      t.text :description
      t.date :due_date
      t.boolean :completed
      t.integer :priority
      t.string :category

      t.timestamps
    end
  end
end
