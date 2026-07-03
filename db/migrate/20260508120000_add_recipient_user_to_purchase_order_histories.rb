class AddRecipientUserToPurchaseOrderHistories < ActiveRecord::Migration[8.0]
  def up
    add_reference :purchase_order_histories, :recipient_user, foreign_key: { to_table: :users }, null: true

    # 既存の発行履歴は「受注者=川村 / 発注者=西野鷹也」で揃える
    kawamura = User.find_by(email: "calmdownyourlife@gmail.com") || User.find_by(id: 5)
    nishino  = User.find_by(email: "takaya314boxing@gmail.com") ||
               User.where("display_name LIKE ?", "%西野%").first

    if kawamura
      PurchaseOrderHistory.where(recipient_user_id: nil).update_all(recipient_user_id: kawamura.id)
    end
    if nishino
      PurchaseOrderHistory.where.not(user_id: nishino.id).update_all(user_id: nishino.id)
    end
  end

  def down
    remove_reference :purchase_order_histories, :recipient_user, foreign_key: { to_table: :users }
  end
end
