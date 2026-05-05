class AddLinkedUserToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :linked_user, null: true, foreign_key: { to_table: :users }
  end
end
