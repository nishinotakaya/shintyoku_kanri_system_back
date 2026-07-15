class CreateTrelloTasks < ActiveRecord::Migration[8.0]
  # Trello (テックリーダーズ) のカードを同期して保持するテーブル。Notion 連携の notion_tasks と同型。
  def change
    create_table :trello_tasks do |t|
      t.string   :trello_card_id, null: false
      t.string   :board_id
      t.string   :board_name
      t.string   :list_name
      t.string   :title, null: false
      t.text     :description
      t.string   :assignee_name
      t.date     :start_date
      t.date     :due_date
      t.string   :url
      t.float    :position
      t.text     :memo
      t.datetime :synced_at

      t.timestamps
    end

    add_index :trello_tasks, :trello_card_id, unique: true
  end
end
