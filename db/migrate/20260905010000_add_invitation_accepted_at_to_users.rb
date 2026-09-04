class AddInvitationAcceptedAtToUsers < ActiveRecord::Migration[8.0]
  def change
    # 招待リンク(署名付きトークン)からの登録完了日時。使用済み招待リンクの再利用防止に使う
    add_column :users, :invitation_accepted_at, :datetime
  end
end
