class AddRecipientUserToPurchaseOrderSettings < ActiveRecord::Migration[8.0]
  def up
    add_reference :purchase_order_settings, :recipient_user, foreign_key: { to_table: :users }, null: true

    # recipient_name に各ユーザーの display_name を含む Setting を、その user に紐付け
    User.where.not(display_name: [ nil, "" ]).find_each do |u|
      key = u.display_name.gsub(/\s+/, "")
      PurchaseOrderSetting.where(recipient_user_id: nil).find_each do |s|
        next if s.recipient_name.blank?
        normalized = s.recipient_name.gsub(/\s+/, "")
        s.update_columns(recipient_user_id: u.id) if normalized.include?(key)
      end
    end
  end

  def down
    remove_reference :purchase_order_settings, :recipient_user, foreign_key: { to_table: :users }
  end
end
